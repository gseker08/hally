package app.hally.hally

import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.telecom.TelecomManager
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Child mode on Android: a paired child's phone measures its own screen time (Usage access) and, once the parents'
 * daily limit is used up, covers every app with a lock page (Display over other apps). The phone app, emergency
 * calls and Hally itself stay usable. The limit, extra minutes and "locked" come from the Hally server, which the
 * service asks every minute with the child's device token; between answers it keeps enforcing the last known limit.
 */
object ChildLock {
    private const val PREFS = "hally_child_lock"

    fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun hasUsageAccess(context: Context): Boolean {
        val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        } else {
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun canDrawOverlays(context: Context) = Settings.canDrawOverlays(context)

    fun start(context: Context, token: String, baseUrl: String) {
        prefs(context).edit().putString("token", token).putString("baseUrl", baseUrl).putBoolean("enabled", true).apply()
        val intent = Intent(context, ChildLockService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    fun stop(context: Context) {
        prefs(context).edit().clear().apply()
        context.stopService(Intent(context, ChildLockService::class.java))
    }

    fun isEnabled(context: Context) = prefs(context).getBoolean("enabled", false)

    /** Seconds of screen time today (since local midnight) in other apps, and the app in front now. */
    fun measure(context: Context): Pair<Int, String?> {
        val usage = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val midnight = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val home = context.packageManager.resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)
            ?.activityInfo?.packageName
        // Hally itself, the system bars and the home screen don't count as screen time.
        val ignored = setOfNotNull(context.packageName, "com.android.systemui", home)
        val events = usage.queryEvents(midnight, now)
        val event = UsageEvents.Event()
        val openSince = HashMap<String, Long>()
        var total = 0L
        var front: String? = null
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val pkg = event.packageName ?: continue
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    openSince[pkg] = event.timeStamp
                    front = pkg
                }
                UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> {
                    val since = openSince.remove(pkg)
                    if (since != null && pkg !in ignored) total += event.timeStamp - since
                    if (front == pkg) front = null
                }
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    // Screen off: whatever was open stops counting.
                    for ((p, since) in openSince) if (p !in ignored) total += event.timeStamp - since
                    openSince.clear()
                    front = null
                }
            }
        }
        for ((p, since) in openSince) if (p !in ignored) total += now - since
        return Pair((total / 1000).toInt(), front)
    }
}

class ChildLockService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var overlay: View? = null
    private var lastReport = 0L
    private var lastReported = -1

    private val tick = object : Runnable {
        override fun run() {
            check()
            handler.postDelayed(this, 15_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!ChildLock.isEnabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = notification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        handler.removeCallbacks(tick)
        handler.post(tick)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        hideOverlay()
        io.shutdownNow()
        super.onDestroy()
    }

    private fun check() {
        if (!ChildLock.hasUsageAccess(this)) return
        val (used, front) = ChildLock.measure(this)
        val prefs = ChildLock.prefs(this)
        val limit = prefs.getInt("limitMinutes", -1)
        val locked = limit >= 0 && used >= limit * 60
        if (locked && !allowed(front)) showOverlay(used) else hideOverlay()

        val now = System.currentTimeMillis()
        if (now - lastReport >= 60_000 || (locked != prefs.getBoolean("locked", false)) || used - lastReported >= 300) {
            lastReport = now
            lastReported = used
            report(used)
        }
    }

    /** The phone app, emergency calls and Hally itself stay usable while locked. */
    private fun allowed(front: String?): Boolean {
        if (front == null) return false
        if (front == packageName) return true
        val dialer = (getSystemService(Context.TELECOM_SERVICE) as? TelecomManager)?.defaultDialerPackage
        return front == dialer || front.contains("emergency") || front == "com.android.phone" || front == "com.android.server.telecom"
    }

    private fun report(used: Int) {
        val prefs = ChildLock.prefs(this)
        val token = prefs.getString("token", null) ?: return
        val base = prefs.getString("baseUrl", null) ?: return
        io.execute {
            try {
                val conn = URL("${base.trimEnd('/')}/api/v1/child/screen").openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-Hally-Child", token)
                conn.setRequestProperty("Idempotency-Key", UUID.randomUUID().toString())
                conn.outputStream.use { it.write("{\"usedSeconds\":$used}".toByteArray()) }
                when (conn.responseCode) {
                    200 -> {
                        val body = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                        val limit = if (body.isNull("limitMinutes")) -1 else body.getInt("limitMinutes")
                        prefs.edit().putInt("limitMinutes", limit).putBoolean("locked", body.optBoolean("locked")).apply()
                    }
                    // A parent unpaired this phone: stop locking it.
                    401 -> handler.post { ChildLock.stop(this) }
                }
                conn.disconnect()
            } catch (_: Exception) {
                // Offline: keep enforcing the last known limit.
            }
        }
    }

    private fun showOverlay(usedSeconds: Int) {
        if (overlay != null || !ChildLock.canDrawOverlays(this)) return
        val tr = Locale.getDefault().language == "tr"
        val cherry = Color.parseColor("#AD5268")
        fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()
        fun text(value: String, size: Float, bold: Boolean = false, color: Int = Color.parseColor("#374B45")) = TextView(this).apply {
            this.text = value
            textSize = size
            gravity = Gravity.CENTER
            setTextColor(color)
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(6), 0, dp(6))
        }
        fun button(label: String, filled: Boolean, onClick: () -> Unit) = Button(this).apply {
            text = label
            isAllCaps = false
            textSize = 16f
            setTextColor(if (filled) Color.WHITE else cherry)
            background = GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(if (filled) Color.parseColor("#914057") else Color.WHITE)
            }
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56)).apply { topMargin = dp(10) }
        }

        val minutes = usedSeconds / 60
        val used = if (minutes >= 60) {
            if (tr) "${minutes / 60} saat ${minutes % 60} dakika" else "${minutes / 60} h ${minutes % 60} min"
        } else {
            if (tr) "$minutes dakika" else "$minutes min"
        }
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#F3E4E7"))
            setPadding(dp(28), dp(48), dp(28), dp(36))
            addView(text("🍒", 64f))
            addView(text(if (tr) "Ekran süren doldu" else "Screen time is up", 26f, bold = true, color = cherry))
            addView(text(if (tr) "Bugün $used kullandın.\nYarın tekrar açılır." else "You used $used today.\nIt opens again tomorrow.", 16f))
            addView(text(if (tr) "Hally'de kirazla süre alabilir ya da annenden/babandan isteyebilirsin." else "In Hally you can buy time with cherries or ask your parents.", 14f))
            addView(button(if (tr) "Hally'yi aç" else "Open Hally", true) {
                packageManager.getLaunchIntentForPackage(packageName)?.let {
                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(it)
                }
                hideOverlay()
            })
            addView(button(if (tr) "Acil arama" else "Emergency call", false) {
                startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:112")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                hideOverlay()
            })
        }
        @Suppress("DEPRECATION")
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.OPAQUE,
        )
        try {
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(view, params)
            overlay = view
        } catch (_: Exception) {
        }
    }

    private fun hideOverlay() {
        val view = overlay ?: return
        overlay = null
        try {
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(view)
        } catch (_: Exception) {
        }
    }

    private fun notification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Hally çocuk modu", NotificationManager.IMPORTANCE_MIN))
        }
        val tr = Locale.getDefault().language == "tr"
        val open = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (tr) "Ekran süresi takip ediliyor" else "Screen time is on")
            .setContentText(if (tr) "Ailen için Hally çocuk modu açık" else "Hally child mode is on for your family")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "hally_child_lock"
        private const val NOTIFICATION_ID = 4711
    }
}

/** Starts the lock again after a restart or an app update. */
class ChildLockBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ChildLock.isEnabled(context)) return
        val service = Intent(context, ChildLockService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service) else context.startService(service)
        } catch (_: Exception) {
        }
    }
}

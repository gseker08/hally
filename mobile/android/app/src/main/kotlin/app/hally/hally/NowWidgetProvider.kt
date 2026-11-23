package app.hally.hally

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONObject

/**
 * Home screen "Şu an" widget: the family's running timers (screen time, homework/reading, sleep).
 *
 * The app saves the list whenever a timer starts or stops (lib/features/home/now_widget.dart). Each clock is an
 * Android Chronometer, so it ticks without the app. Durdur calls Dart in the background (home_widget), which
 * stops the timer on the server and removes the row. A timer past its server cap is hidden.
 */
class NowWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        val timers = timers(widgetData, now)
        val stop = widgetData.getString("now.stop", null) ?: "Durdur"

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.now_widget)
            widgetData.getString("now.title", null)?.let { views.setTextViewText(R.id.now_title, it) }
            val count = widgetData.getString("now.count", null)
            views.setTextViewText(R.id.now_count, if (timers.isEmpty() || count == null) "" else String.format(count, timers.size))

            ROWS.forEachIndexed { i, row ->
                val t = timers.getOrNull(i)
                views.setViewVisibility(row.root, if (t == null) View.GONE else View.VISIBLE)
                if (t == null) return@forEachIndexed
                views.setTextViewText(row.emoji, t.optString("emoji"))
                views.setTextViewText(row.title, t.optString("title"))
                views.setTextViewText(row.body, t.optString("body"))
                // Chronometer counts from an elapsedRealtime base; map the wall-clock start onto it.
                val base = SystemClock.elapsedRealtime() - (now - t.optLong("since"))
                views.setChronometer(row.clock, base, null, true)
                views.setTextViewText(row.stop, stop)
                val uri = Uri.parse("hally://timer/stop").buildUpon()
                    .appendQueryParameter("type", t.optString("type"))
                    .appendQueryParameter("family", t.optString("familyId"))
                    .appendQueryParameter("child", t.optString("childId"))
                    .build()
                views.setOnClickPendingIntent(row.stop, HomeWidgetBackgroundIntent.getBroadcast(context, uri))
            }

            val empty = timers.isEmpty()
            views.setViewVisibility(R.id.now_message, if (empty) View.VISIBLE else View.GONE)
            widgetData.getString("now.empty", null)?.let { views.setTextViewText(R.id.now_message, it) }

            views.setOnClickPendingIntent(R.id.now_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun timers(data: SharedPreferences, now: Long): List<JSONObject> {
        val items = try {
            JSONArray(data.getString("now.items", null) ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }
        val result = mutableListOf<JSONObject>()
        for (i in 0 until items.length()) {
            val t = items.optJSONObject(i) ?: continue
            if (!t.isNull("until") && t.optLong("until") <= now) continue
            result.add(t)
        }
        return result
    }

    private data class Row(val root: Int, val emoji: Int, val title: Int, val body: Int, val clock: Int, val stop: Int)

    private companion object {
        val ROWS = listOf(
            Row(R.id.now1, R.id.now1_emoji, R.id.now1_title, R.id.now1_body, R.id.now1_clock, R.id.now1_stop),
            Row(R.id.now2, R.id.now2_emoji, R.id.now2_title, R.id.now2_body, R.id.now2_clock, R.id.now2_stop),
            Row(R.id.now3, R.id.now3_emoji, R.id.now3_title, R.id.now3_body, R.id.now3_clock, R.id.now3_stop),
        )
    }
}

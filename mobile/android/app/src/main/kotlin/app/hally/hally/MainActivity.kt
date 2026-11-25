package app.hally.hally

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Child mode screen lock (ChildLock.kt).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hally/child_lock").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "usageAccess" to ChildLock.hasUsageAccess(this),
                        "overlay" to ChildLock.canDrawOverlays(this),
                        "running" to ChildLock.isEnabled(this),
                    ),
                )
                "openUsageAccess" -> {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    result.success(null)
                }
                "openOverlay" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "start" -> {
                    ChildLock.start(this, call.argument<String>("token")!!, call.argument<String>("baseUrl")!!)
                    result.success(null)
                }
                "stop" -> {
                    ChildLock.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

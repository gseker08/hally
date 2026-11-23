package app.hally.hally

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Home screen "Today" widget: the next three events and tasks of today.
 *
 * The app saves today's list (lib/features/home/today_widget.dart) whenever Today loads. The widget hides items
 * that have passed by itself, so it stays right while the app is closed; a list from an earlier day is never
 * shown, the widget asks to open the app instead. Tapping anywhere opens the app.
 */
class TodayWidgetProvider : HomeWidgetProvider() {
    private data class Row(val time: String, val title: String)

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        val locale = Locale(widgetData.getString("today.lang", null) ?: Locale.getDefault().language)
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(now))
        val fresh = widgetData.getString("today.day", null) == today
        val rows = if (fresh) rows(widgetData, now) else emptyList()

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.today_widget)
            widgetData.getString("today.title", null)?.let { views.setTextViewText(R.id.today_title, it) }
            views.setTextViewText(R.id.today_date, SimpleDateFormat("d MMMM EEEE", locale).format(Date(now)))

            ROWS.forEachIndexed { i, (rowId, timeId, titleId) ->
                val row = rows.getOrNull(i)
                views.setViewVisibility(rowId, if (row == null) View.GONE else View.VISIBLE)
                if (row != null) {
                    views.setTextViewText(timeId, row.time)
                    views.setTextViewText(titleId, row.title)
                }
            }

            val message = when {
                !fresh -> widgetData.getString("today.stale", null) ?: context.getString(R.string.today_widget_stale)
                rows.isEmpty() -> widgetData.getString("today.empty", null)
                rows.size > ROWS.size -> widgetData.getString("today.more", null)?.let { String.format(it, rows.size - ROWS.size) }
                else -> null
            }
            views.setViewVisibility(R.id.today_message, if (message == null) View.GONE else View.VISIBLE)
            message?.let { views.setTextViewText(R.id.today_message, it) }

            views.setOnClickPendingIntent(R.id.today_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    /** Items still ahead: timed ones until 15 minutes after they start, all-day ones and tasks without a time all day. */
    private fun rows(data: SharedPreferences, now: Long): List<Row> {
        val items = try {
            JSONArray(data.getString("today.items", null) ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }
        val clock = SimpleDateFormat("HH:mm", Locale.US)
        val allDay = data.getString("today.allDay", null) ?: ""
        val task = data.getString("today.taskMark", null) ?: ""
        val result = mutableListOf<Row>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val title = item.optString("title")
            if (item.isNull("at")) {
                result.add(Row(if (item.optString("kind") == "task") task else allDay, title))
                continue
            }
            val at = item.optLong("at")
            if (at + GRACE_MS > now) result.add(Row(clock.format(Date(at)), title))
        }
        return result
    }

    private companion object {
        const val GRACE_MS = 15 * 60 * 1000L
        val ROWS = listOf(
            Triple(R.id.row1, R.id.row1_time, R.id.row1_title),
            Triple(R.id.row2, R.id.row2_time, R.id.row2_title),
            Triple(R.id.row3, R.id.row3_time, R.id.row3_title),
        )
    }
}

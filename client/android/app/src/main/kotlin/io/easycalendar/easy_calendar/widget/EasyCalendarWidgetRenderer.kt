package io.easycalendar.easy_calendar.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import io.easycalendar.easy_calendar.MainActivity
import io.easycalendar.easy_calendar.R
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlin.math.absoluteValue

object EasyCalendarWidgetUpdater {
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        DueWidgetProvider.update(
            context,
            manager,
            manager.getAppWidgetIds(ComponentName(context, DueWidgetProvider::class.java)),
        )
        WeekWidgetProvider.update(
            context,
            manager,
            manager.getAppWidgetIds(ComponentName(context, WeekWidgetProvider::class.java)),
        )
    }
}

internal object EasyCalendarWidgetRenderer {
    private val shortDateTime = DateTimeFormatter.ofPattern("M月d日 HH:mm", Locale.SIMPLIFIED_CHINESE)
    private val shortDate = DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE)
    private val timeOnly = DateTimeFormatter.ofPattern("HH:mm", Locale.SIMPLIFIED_CHINESE)
    private val weekRangeDate = DateTimeFormatter.ofPattern("M.d", Locale.SIMPLIFIED_CHINESE)
    private val weekDayNames = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

    private val dueRows = intArrayOf(R.id.due_row_1, R.id.due_row_2, R.id.due_row_3)
    private val dueDates = intArrayOf(R.id.due_date_1, R.id.due_date_2, R.id.due_date_3)
    private val dueTitles = intArrayOf(R.id.due_title_1, R.id.due_title_2, R.id.due_title_3)
    private val weekRows = intArrayOf(
        R.id.week_row_1,
        R.id.week_row_2,
        R.id.week_row_3,
        R.id.week_row_4,
        R.id.week_row_5,
        R.id.week_row_6,
        R.id.week_row_7,
    )
    private val weekDates = intArrayOf(
        R.id.week_date_1,
        R.id.week_date_2,
        R.id.week_date_3,
        R.id.week_date_4,
        R.id.week_date_5,
        R.id.week_date_6,
        R.id.week_date_7,
    )
    private val weekTitles = intArrayOf(
        R.id.week_title_1,
        R.id.week_title_2,
        R.id.week_title_3,
        R.id.week_title_4,
        R.id.week_title_5,
        R.id.week_title_6,
        R.id.week_title_7,
    )
    private val weekCounts = intArrayOf(
        R.id.week_count_1,
        R.id.week_count_2,
        R.id.week_count_3,
        R.id.week_count_4,
        R.id.week_count_5,
        R.id.week_count_6,
        R.id.week_count_7,
    )

    fun due(context: Context, snapshot: WidgetSnapshot?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_due)
        val now = Instant.now()
        val zoneId = snapshot?.zoneId ?: java.time.ZoneId.systemDefault()
        val nearest = snapshot?.dueItems.orEmpty()
            .filter { it.type == "task" && it.dueAt != null }
            .sortedWith(
                compareBy<WidgetItem> {
                    Duration.between(now, it.dueAt).toMillis().absoluteValue
                }.thenBy { it.dueAt },
            )
            .take(3)
        views.setTextViewText(R.id.due_summary, "${nearest.size} 项")
        views.setViewVisibility(
            R.id.due_empty,
            if (nearest.isEmpty()) View.VISIBLE else View.GONE,
        )
        dueRows.indices.forEach { index ->
            val item = nearest.getOrNull(index)
            views.setViewVisibility(dueRows[index], if (item == null) View.GONE else View.VISIBLE)
            if (item != null) {
                views.setTextViewText(
                    dueDates[index],
                    formatDue(item, now, zoneId),
                )
                views.setTextViewText(dueTitles[index], item.title)
            }
        }
        views.setOnClickPendingIntent(
            R.id.widget_due_root,
            openAppIntent(context, "easycalendar://due"),
        )
        return views
    }

    fun week(context: Context, snapshot: WidgetSnapshot?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_week)
        val zoneId = snapshot?.zoneId ?: java.time.ZoneId.systemDefault()
        val today = LocalDate.now(zoneId)
        val weekStart = today.with(TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val weekEnd = weekStart.plusDays(6)
        val eventsByDay = snapshot?.weekEvents.orEmpty()
            .filter { it.type == "event" && it.startAt != null }
            .groupBy { it.startAt!!.atZone(zoneId).toLocalDate() }
        val eventCount = eventsByDay.values.sumOf(List<WidgetItem>::size)
        views.setTextViewText(
            R.id.week_range,
            "${weekStart.format(weekRangeDate)} - ${weekEnd.format(weekRangeDate)} · $eventCount 项",
        )
        weekRows.indices.forEach { index ->
            val date = weekStart.plusDays(index.toLong())
            val events = eventsByDay[date].orEmpty().sortedBy(WidgetItem::startAt)
            views.setTextViewText(weekDates[index], "${weekDayNames[index]} ${date.dayOfMonth}")
            views.setTextViewText(
                weekTitles[index],
                events.firstOrNull()?.let { formatWeekEvent(it, zoneId) } ?: "无安排",
            )
            views.setTextViewText(
                weekCounts[index],
                if (events.size > 1) "+${events.size - 1}" else "",
            )
            val isToday = date == today
            views.setInt(
                weekDates[index],
                "setBackgroundResource",
                if (isToday) R.drawable.widget_today_background else android.R.color.transparent,
            )
            views.setTextColor(
                weekDates[index],
                color(
                    context,
                    if (isToday) R.color.widget_today_text else R.color.widget_secondary_text,
                ),
            )
        }
        views.setOnClickPendingIntent(
            R.id.widget_week_root,
            openAppIntent(context, "easycalendar://today"),
        )
        return views
    }

    private fun formatDue(item: WidgetItem, now: Instant, zoneId: java.time.ZoneId): String {
        val dueAt = item.dueAt ?: return ""
        val due = dueAt.atZone(zoneId)
        val today = now.atZone(zoneId).toLocalDate()
        return when (due.toLocalDate()) {
            today -> if (item.allDay) "今天" else "今天 ${due.format(timeOnly)}"
            today.plusDays(1) -> if (item.allDay) "明天" else "明天 ${due.format(timeOnly)}"
            else -> if (dueAt.isBefore(now)) {
                "逾期 ${due.format(shortDate)}"
            } else if (item.allDay) {
                due.format(shortDate)
            } else {
                due.format(shortDateTime)
            }
        }
    }

    private fun formatWeekEvent(item: WidgetItem, zoneId: java.time.ZoneId): String {
        if (item.allDay) return item.title
        val start = item.startAt?.atZone(zoneId)?.format(timeOnly) ?: return item.title
        return "$start  ${item.title}"
    }

    private fun openAppIntent(context: Context, destination: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(destination)
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            destination.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    @Suppress("DEPRECATION")
    private fun color(context: Context, colorId: Int): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.resources.getColor(colorId, context.theme)
        } else {
            context.resources.getColor(colorId)
        }
}

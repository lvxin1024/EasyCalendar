package io.easycalendar.easy_calendar.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import io.easycalendar.easy_calendar.MainActivity
import io.easycalendar.easy_calendar.R
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlin.math.ceil

object EasyCalendarWidgetUpdater {
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        DueWidgetProvider.update(
            context,
            manager,
            manager.getAppWidgetIds(android.content.ComponentName(context, DueWidgetProvider::class.java)),
        )
        WeekWidgetProvider.update(
            context,
            manager,
            manager.getAppWidgetIds(android.content.ComponentName(context, WeekWidgetProvider::class.java)),
        )
    }
}

internal object EasyCalendarWidgetRenderer {
    private val shortDateTime = DateTimeFormatter.ofPattern("M月d日 HH:mm", Locale.SIMPLIFIED_CHINESE)
    private val shortDate = DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE)
    private val timeOnly = DateTimeFormatter.ofPattern("HH:mm", Locale.SIMPLIFIED_CHINESE)
    private val weekRangeDate = DateTimeFormatter.ofPattern("M.d", Locale.SIMPLIFIED_CHINESE)
    private val weekDayNames = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")
    private val defaultQuotes = listOf(
        "every day u fight like ur running out of time",
        "do it with all your heart",
        "small steps still move you forward",
    )

    private val dueRows = intArrayOf(R.id.due_row_1, R.id.due_row_2, R.id.due_row_3)
    private val dueChecks = intArrayOf(R.id.due_check_1, R.id.due_check_2, R.id.due_check_3)
    private val dueDates = intArrayOf(R.id.due_date_1, R.id.due_date_2, R.id.due_date_3)
    private val dueTitles = intArrayOf(R.id.due_title_1, R.id.due_title_2, R.id.due_title_3)
    private val weekDays = intArrayOf(
        R.id.week_day_1, R.id.week_day_2, R.id.week_day_3, R.id.week_day_4,
        R.id.week_day_5, R.id.week_day_6, R.id.week_day_7,
    )
    private val weekCells = intArrayOf(
        R.id.week_cell_1, R.id.week_cell_2, R.id.week_cell_3, R.id.week_cell_4,
        R.id.week_cell_5, R.id.week_cell_6, R.id.week_cell_7,
    )

    fun due(context: Context, snapshot: WidgetSnapshot?, widgetId: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_due)
        val now = Instant.now()
        val zoneId = snapshot?.zoneId ?: java.time.ZoneId.systemDefault()
        val nearest = snapshot?.dueItems.orEmpty()
            .filter { it.type == "task" && it.dueAt != null }
            .sortedBy { it.dueAt }
            .take(3)
        val isEmpty = nearest.isEmpty()
        views.setTextViewText(R.id.due_summary, if (isEmpty) "" else "do what you do")
        views.setViewVisibility(R.id.due_empty, if (isEmpty) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.due_refresh, if (isEmpty) View.VISIBLE else View.GONE)
        if (isEmpty) {
            val quotes = snapshot?.quotes.orEmpty().ifEmpty { defaultQuotes }
            val index = WidgetSnapshotStore.quoteIndex(context, widgetId) % quotes.size
            views.setTextViewText(R.id.due_empty, quotes[index])
            val shuffle = shuffleQuoteIntent(context, widgetId)
            views.setOnClickPendingIntent(R.id.due_empty, shuffle)
            views.setOnClickPendingIntent(R.id.due_refresh, shuffle)
        }
        dueRows.indices.forEach { index ->
            val item = nearest.getOrNull(index)
            views.setViewVisibility(dueRows[index], if (item == null) View.GONE else View.VISIBLE)
            if (item != null) {
                views.setTextViewText(dueDates[index], formatDue(item, now, zoneId))
                views.setTextViewText(dueTitles[index], item.title)
                views.setOnClickPendingIntent(
                    dueChecks[index],
                    openAppIntent(context, "easycalendar://complete/${Uri.encode(item.id)}"),
                )
            }
        }
        views.setOnClickPendingIntent(R.id.widget_due_root, openAppIntent(context, "easycalendar://due"))
        return views
    }

    fun week(
        context: Context,
        snapshot: WidgetSnapshot?,
        minWidth: Int,
        minHeight: Int,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_week)
        val zoneId = snapshot?.zoneId ?: java.time.ZoneId.systemDefault()
        val today = LocalDate.now(zoneId)
        val weekStart = today.with(TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val weekEnd = weekStart.plusDays(6)
        val events = snapshot?.weekEvents.orEmpty()
            .filter { it.type == "event" && it.startAt != null }
        views.setTextViewText(
            R.id.week_range,
            "${weekStart.format(weekRangeDate)} - ${weekEnd.format(weekRangeDate)} · ${events.size} 项",
        )
        weekDays.indices.forEach { index ->
            val date = weekStart.plusDays(index.toLong())
            val name = if (minWidth < 330) weekDayNames[index].takeLast(1) else weekDayNames[index]
            views.setTextViewText(weekDays[index], "$name\n${date.dayOfMonth}")
            val isToday = date == today
            views.setInt(
                weekDays[index],
                "setBackgroundResource",
                if (isToday) R.drawable.widget_today_background else android.R.color.transparent,
            )
            views.setTextColor(
                weekDays[index],
                color(context, if (isToday) R.color.widget_today_text else R.color.widget_secondary_text),
            )
        }

        views.removeAllViews(R.id.week_grid_rows)
        val timedEvents = events.filter { !it.allDay }
        val allDayEvents = events.filter { it.allDay }
        val totalRows = ((minHeight - 72) / 30).coerceIn(4, 10)
        var timedRows = totalRows
        if (allDayEvents.isNotEmpty()) {
            views.addView(
                R.id.week_grid_rows,
                gridRow(context, "全天", weekStart, allDayEvents, zoneId, minWidth),
            )
            timedRows = (timedRows - 1).coerceAtLeast(3)
        }

        val zonedStarts = timedEvents.mapNotNull { it.startAt?.atZone(zoneId) }
        val zonedEnds = timedEvents.mapNotNull { (it.endAt ?: it.startAt)?.atZone(zoneId) }
        val startHour = minOf(8, zonedStarts.minOfOrNull { it.hour } ?: 8)
        val latestStartHour = zonedStarts.maxOfOrNull { it.hour + 1 } ?: 20
        val latestEndHour = zonedEnds.maxOfOrNull {
            it.hour + if (it.minute > 0 || it.second > 0) 1 else 0
        } ?: 20
        val endHour = minOf(
            24,
            maxOf(20, latestStartHour, latestEndHour, startHour + timedRows),
        )
        val stepHours = ceil((endHour - startHour).toDouble() / timedRows).toInt().coerceAtLeast(1)
        val actualRows = ceil((endHour - startHour).toDouble() / stepHours)
            .toInt()
            .coerceIn(1, timedRows)
        repeat(actualRows) { rowIndex ->
            val rowStart = startHour + rowIndex * stepHours
            val rowEnd = minOf(24, rowStart + stepHours)
            views.addView(
                R.id.week_grid_rows,
                gridRow(
                    context,
                    "%02d:00".format(rowStart),
                    weekStart,
                    timedEvents,
                    zoneId,
                    minWidth,
                    rowStart,
                    rowEnd,
                ),
            )
        }
        views.setOnClickPendingIntent(R.id.widget_week_root, openAppIntent(context, "easycalendar://today"))
        return views
    }

    private fun gridRow(
        context: Context,
        label: String,
        weekStart: LocalDate,
        events: List<WidgetItem>,
        zoneId: java.time.ZoneId,
        minWidth: Int,
        startHour: Int? = null,
        endHour: Int? = null,
    ): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.widget_week_time_row)
        row.setTextViewText(R.id.week_time_label, label)
        weekCells.indices.forEach { dayIndex ->
            val date = weekStart.plusDays(dayIndex.toLong())
            val dayEvents = events
                .filter { event ->
                    val eventStart = event.startAt?.atZone(zoneId) ?: return@filter false
                    if (startHour == null || endHour == null) {
                        return@filter eventStart.toLocalDate() == date
                    }
                    val slotStart = date.atStartOfDay(zoneId).plusHours(startHour.toLong())
                    val slotEnd = date.atStartOfDay(zoneId).plusHours(endHour.toLong())
                    val eventEnd = (event.endAt ?: event.startAt)
                        ?.atZone(zoneId)
                        ?.takeIf { it.isAfter(eventStart) }
                        ?: eventStart.plusMinutes(1)
                    eventStart.isBefore(slotEnd) && eventEnd.isAfter(slotStart)
                }
                .sortedBy(WidgetItem::startAt)
            val displayEvents = dayEvents.filter { event ->
                if (startHour == null || endHour == null) {
                    true
                } else {
                    val hour = event.startAt?.atZone(zoneId)?.hour ?: return@filter false
                    hour in startHour until endHour
                }
            }
            val text = displayEvents.joinToString("\n") { event ->
                if (event.allDay || minWidth < 380) event.title
                else "${event.startAt!!.atZone(zoneId).format(timeOnly)} ${event.title}"
            }
            row.setTextViewText(weekCells[dayIndex], text)
            row.setInt(
                weekCells[dayIndex],
                "setBackgroundResource",
                if (dayEvents.isEmpty()) R.drawable.widget_grid_cell else R.drawable.widget_grid_event,
            )
            dayEvents.firstOrNull()?.let { event ->
                row.setOnClickPendingIntent(
                    weekCells[dayIndex],
                    openAppIntent(context, "easycalendar://item/${Uri.encode(event.id)}"),
                )
            }
        }
        return row
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

    private fun shuffleQuoteIntent(context: Context, widgetId: Int): PendingIntent {
        val intent = Intent(context, DueWidgetProvider::class.java).apply {
            action = DueWidgetProvider.ACTION_SHUFFLE_QUOTE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
        }
        return PendingIntent.getBroadcast(
            context,
            widgetId,
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

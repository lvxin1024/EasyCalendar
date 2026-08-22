package io.easycalendar.easy_calendar.widget

import android.app.PendingIntent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
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
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.StyleSpan
import kotlin.math.ceil
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan

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
    fun due(context: Context, snapshot: WidgetSnapshot?, widgetId: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_due)
        val now = Instant.now()
        val zoneId = snapshot?.zoneId ?: java.time.ZoneId.systemDefault()
        val nearest = snapshot?.dueItems.orEmpty()
            .filter { it.type == "task" && it.dueAt != null }
            .sortedBy { it.dueAt }
            .take(3)
        val isEmpty = nearest.isEmpty()
        views.setTextViewText(R.id.due_summary, if (isEmpty) "" else italic("do what you do"))
        views.setViewVisibility(R.id.due_empty, if (isEmpty) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.due_refresh, if (isEmpty) View.VISIBLE else View.GONE)
        if (isEmpty) {
            val quotes = snapshot?.quotes.orEmpty().ifEmpty { defaultQuotes }
            val index = WidgetSnapshotStore.quoteIndex(context, widgetId) % quotes.size
            views.setTextViewText(R.id.due_empty, italic(quotes[index]))
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
                    completeDueIntent(context, widgetId, item.id),
                )
            }
        }
        return views
    }

    fun week(
        context: Context,
        snapshot: WidgetSnapshot?,
        minWidth: Int,
        minHeight: Int,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_week)
        val bitmap = buildWeekSnapshot(context, snapshot, minWidth, minHeight)
        views.setImageViewBitmap(R.id.week_snapshot, bitmap)
        views.setOnClickPendingIntent(R.id.widget_week_root, openAppIntent(context, "easycalendar://today"))
        views.setOnClickPendingIntent(R.id.week_snapshot, openAppIntent(context, "easycalendar://today"))
        return views
    }

    private fun buildWeekSnapshot(
        context: Context,
        snapshot: WidgetSnapshot?,
        minWidth: Int,
        minHeight: Int,
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        val width = max(360, (minWidth * density).roundToInt())
        val height = max(260, (minHeight * density).roundToInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val zoneId = snapshot?.zoneId ?: ZoneId.systemDefault()
        val today = LocalDate.now(zoneId)
        val weekStart = today.with(TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val weekEnd = weekStart.plusDays(6)
        val events = (snapshot?.calendarEvents.orEmpty().ifEmpty { snapshot?.weekEvents.orEmpty() })
            .filter { it.startAt != null }
        val timedEvents = events.filter { !it.allDay }
        val allDayEvents = events.filter { it.allDay }

        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), bg)

        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_primary_text)
            textSize = 15f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val rangePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_secondary_text)
            textSize = 11f * density
        }
        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_secondary_text)
            textSize = 11f * density
        }
        val dayPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_primary_text)
            textSize = 12f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val eventPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 10f * density
            color = Color.WHITE
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1f * density
            color = color(context, R.color.widget_border)
        }
        val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1f * density
            color = color(context, R.color.widget_border)
        }
        val todayFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_today_surface)
        }
        val eventBackgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val currentLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_coral)
            strokeWidth = 2f * density
        }
        val currentLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_coral)
            textSize = 10f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }

        val pad = (10f * density)
        val titleTop = 20f * density
        val headerBottom = 62f * density
        val allDayTop = 68f * density
        val gridTop = if (allDayEvents.isNotEmpty()) 88f * density else 72f * density
        val bottomPad = 12f * density
        val leftGutter = 52f * density
        val rightPad = 8f * density
        val gridLeft = leftGutter
        val gridRight = width.toFloat() - rightPad
        val gridWidth = max(1f, gridRight - gridLeft)
        val gridHeight = max(1f, height.toFloat() - gridTop - bottomPad)
        val dayWidth = gridWidth / 7f

        canvas.drawText("周日程", pad, titleTop, titlePaint)
        val range = "${weekStart.format(weekRangeDate)} - ${weekEnd.format(weekRangeDate)} · ${events.size} 项"
        val rangeWidth = rangePaint.measureText(range)
        canvas.drawText(range, width - rightPad - rangeWidth, titleTop, rangePaint)

        drawDayHeaders(
            canvas = canvas,
            today = today,
            weekStart = weekStart,
            gridLeft = gridLeft,
            dayWidth = dayWidth,
            headerBottom = headerBottom,
            dayPaint = dayPaint,
            todayFillPaint = todayFillPaint,
        )

        if (allDayEvents.isNotEmpty()) {
            drawAllDaySummary(
                canvas = canvas,
                events = allDayEvents,
                left = gridLeft,
                top = allDayTop,
                right = gridRight,
                paint = labelPaint,
                eventPaint = eventPaint,
                eventBackgroundPaint = eventBackgroundPaint,
                context = context,
            )
        }

        val rowCount = 24
        val slotHeight = gridHeight / rowCount

        for (rowIndex in 0..rowCount) {
            val y = gridTop + slotHeight * rowIndex
            canvas.drawLine(gridLeft, y, gridRight, y, gridPaint)
            if (rowIndex < rowCount) {
                val hour = rowIndex
                val timeLabel = "%02d:00".format(hour)
                val baseline = y + slotHeight * 0.62f
                canvas.drawText(timeLabel, pad, baseline, labelPaint)
            }
        }
        canvas.drawText("24:00", pad, height.toFloat() - 2f * density, labelPaint)

        for (dayIndex in 0 until 8) {
            val x = gridLeft + dayWidth * dayIndex
            canvas.drawLine(x, gridTop, x, gridTop + gridHeight, gridPaint)
        }

        for (dayIndex in 0 until 7) {
            val date = weekStart.plusDays(dayIndex.toLong())
            val dayStart = date.atStartOfDay(zoneId)
            val dayEnd = dayStart.plusDays(1)
            val cellLeft = gridLeft + dayWidth * dayIndex + 3f * density
            val cellRight = gridLeft + dayWidth * (dayIndex + 1) - 3f * density
            for (event in timedEvents) {
                val start = event.startAt?.atZone(zoneId) ?: continue
                val end = (event.endAt ?: event.startAt)
                    ?.atZone(zoneId)
                    ?.takeIf { it.isAfter(start) }
                    ?: start.plusMinutes(30)
                val overlapStart = maxOf(start, dayStart)
                val overlapEnd = minOf(end, dayEnd)
                if (!overlapEnd.isAfter(overlapStart)) continue
                val startMinutes = overlapStart.hour * 60 + overlapStart.minute
                val endMinutes = overlapEnd.hour * 60 + overlapEnd.minute
                val y0 = gridTop + (startMinutes / 60f) * slotHeight
                val y1 = gridTop + (endMinutes / 60f) * slotHeight
                val top = min(y0, y1)
                val bottom = max(top + 12f * density, y1)
                val block = RectF(cellLeft, top + 1f, cellRight, min(bottom - 1f, gridTop + gridHeight - 1f))
                eventBackgroundPaint.color = eventColor(event)
                canvas.drawRoundRect(block, 6f * density, 6f * density, eventBackgroundPaint)
                canvas.drawRoundRect(block, 6f * density, 6f * density, borderPaint)
                drawTextInside(canvas, event.title, block, eventPaint)
            }
        }

        val now = Instant.now().atZone(zoneId)
        val nowMinutes = now.hour * 60 + now.minute
        if (nowMinutes in 0..(24 * 60)) {
            val y = gridTop + (nowMinutes / 60f) * slotHeight
            canvas.drawLine(gridLeft, y, gridRight, y, currentLinePaint)
            canvas.drawCircle(gridLeft + 6f * density, y, 3f * density, currentLinePaint)
            canvas.drawText("现在", gridLeft + 12f * density, y - 4f * density, currentLabelPaint)
        }

        return bitmap
    }

    private fun drawDayHeaders(
        canvas: Canvas,
        today: LocalDate,
        weekStart: LocalDate,
        gridLeft: Float,
        dayWidth: Float,
        headerBottom: Float,
        dayPaint: Paint,
        todayFillPaint: Paint,
    ) {
        for (dayIndex in 0 until 7) {
            val date = weekStart.plusDays(dayIndex.toLong())
            val left = gridLeft + dayWidth * dayIndex
            val right = left + dayWidth
            if (date == today) {
                canvas.drawRect(left, 16f * dayPaint.textSize / 12f, right, headerBottom, todayFillPaint)
            }
            val label = "${weekDayNames[dayIndex].takeLast(1)}${date.dayOfMonth}"
            val textWidth = dayPaint.measureText(label)
            val x = left + (dayWidth - textWidth) / 2f
            canvas.drawText(label, x, headerBottom - 14f, dayPaint)
        }
    }

    private fun drawAllDaySummary(
        canvas: Canvas,
        events: List<WidgetItem>,
        left: Float,
        top: Float,
        right: Float,
        paint: Paint,
        eventPaint: Paint,
        eventBackgroundPaint: Paint,
        context: Context,
    ) {
        val text = events.take(3).joinToString(" / ") { it.title }
        val label = if (events.size > 3) "$text +${events.size - 3}" else text
        val block = RectF(left, top, right, top + 16f * context.resources.displayMetrics.density)
        canvas.drawRoundRect(block, 6f * context.resources.displayMetrics.density, 6f * context.resources.displayMetrics.density, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = color(context, R.color.widget_today_surface)
        })
        canvas.drawText("全天", left + 6f * context.resources.displayMetrics.density, top + 12f * context.resources.displayMetrics.density, paint)
        val chips = events.take(3)
        var cursorX = left + 34f * context.resources.displayMetrics.density
        val baseline = top + 12f * context.resources.displayMetrics.density
        for (event in chips) {
            val chipText = "■ ${event.title}"
            val chipWidth = eventPaint.measureText(chipText) + 14f * context.resources.displayMetrics.density
            if (cursorX + chipWidth > right) break
            val chipRect = RectF(cursorX, top + 2f * context.resources.displayMetrics.density, cursorX + chipWidth, top + 14f * context.resources.displayMetrics.density)
            eventBackgroundPaint.color = eventColor(event)
            canvas.drawRoundRect(chipRect, 6f * context.resources.displayMetrics.density, 6f * context.resources.displayMetrics.density, eventBackgroundPaint)
            canvas.drawText(chipText, cursorX + 6f * context.resources.displayMetrics.density, baseline, eventPaint)
            cursorX += chipWidth + 6f * context.resources.displayMetrics.density
        }
        if (events.size > 3) {
            canvas.drawText("+${events.size - 3}", cursorX, baseline, paint)
        }
    }

    private fun drawTextInside(canvas: Canvas, text: String, block: RectF, paint: Paint) {
        val maxWidth = block.width() - 8f
        if (maxWidth <= 0f) return
        val displayText = ellipsize(text, paint, maxWidth)
        val textHeight = paint.fontMetrics.run { descent - ascent }
        val x = block.left + 4f
        val y = block.top + (block.height() + textHeight) / 2f - paint.fontMetrics.descent
        canvas.drawText(displayText, x, y, paint)
    }

    private fun ellipsize(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        var end = text.length
        while (end > 1 && paint.measureText(text.substring(0, end) + "…") > maxWidth) {
            end--
        }
        return text.substring(0, end) + "…"
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

    private fun completeDueIntent(
        context: Context,
        widgetId: Int,
        itemId: String,
    ): PendingIntent {
        val intent = Intent(context, DueWidgetProvider::class.java).apply {
            action = DueWidgetProvider.ACTION_COMPLETE_DUE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            putExtra(DueWidgetProvider.EXTRA_ITEM_ID, itemId)
        }
        return PendingIntent.getBroadcast(
            context,
            itemId.hashCode() xor widgetId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun italic(text: String): CharSequence =
        SpannableString(text).apply {
            setSpan(StyleSpan(Typeface.ITALIC), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

    private fun rowsForHeight(minHeight: Int): Int =
        ((minHeight - 56) / 34).coerceIn(5, 8)

    private fun eventColor(event: WidgetItem): Int =
        when (abs(event.id.hashCode()) % 4) {
            0 -> 0xFF426B68.toInt()
            1 -> 0xFFB23A48.toInt()
            2 -> 0xFF6A5ACD.toInt()
            else -> 0xFFCC7A00.toInt()
        }

    @Suppress("DEPRECATION")
    private fun color(context: Context, colorId: Int): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.resources.getColor(colorId, context.theme)
        } else {
            context.resources.getColor(colorId)
        }
}

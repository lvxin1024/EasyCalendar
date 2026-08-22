package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent

class DueWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_SHUFFLE_QUOTE) return
        val widgetId = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        )
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return
        WidgetSnapshotStore.advanceQuote(context, widgetId)
        update(context, AppWidgetManager.getInstance(context), intArrayOf(widgetId))
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        update(context, appWidgetManager, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        update(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    companion object {
        fun update(
            context: Context,
            manager: AppWidgetManager,
            widgetIds: IntArray,
        ) {
            val snapshot = WidgetSnapshotStore.read(context)
            widgetIds.forEach { id ->
                manager.updateAppWidget(id, EasyCalendarWidgetRenderer.due(context, snapshot, id))
            }
        }

        const val ACTION_SHUFFLE_QUOTE =
            "io.easycalendar.easy_calendar.widget.SHUFFLE_QUOTE"
    }
}

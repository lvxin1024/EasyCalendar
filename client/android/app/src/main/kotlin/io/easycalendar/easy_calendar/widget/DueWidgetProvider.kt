package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

class DueWidgetProvider : AppWidgetProvider() {
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
                manager.updateAppWidget(id, EasyCalendarWidgetRenderer.due(context, snapshot))
            }
        }
    }
}

package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

class WeekWidgetProvider : AppWidgetProvider() {
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
                val options = manager.getAppWidgetOptions(id)
                manager.updateAppWidget(
                    id,
                    EasyCalendarWidgetRenderer.week(
                        context,
                        snapshot,
                        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250),
                        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 250),
                    ),
                )
            }
        }
    }
}

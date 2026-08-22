package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.Log

class WeekWidgetProvider : AppWidgetProvider() {
    override fun onDisabled(context: Context) {
        WeekWidgetRefreshScheduler.cancel(context)
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
                try {
                    val options = manager.getAppWidgetOptions(id)
                    val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
                    val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 250)
                    manager.updateAppWidget(
                        id,
                        EasyCalendarWidgetRenderer.week(
                            context,
                            snapshot,
                            minWidth,
                            minHeight,
                        ),
                    )
                } catch (error: Throwable) {
                    Log.e("WeekWidgetProvider", "Week widget update failed", error)
                    manager.updateAppWidget(id, WeekWidgetFallback.views(context))
                }
            }
            WeekWidgetRefreshScheduler.schedule(context)
        }

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            update(
                context,
                manager,
                manager.getAppWidgetIds(
                    android.content.ComponentName(context, WeekWidgetProvider::class.java),
                ),
            )
        }
    }
}

package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent

class DueWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_SHUFFLE_QUOTE -> {
                val widgetId = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID,
                )
                if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return
                WidgetSnapshotStore.advanceQuote(context, widgetId)
                update(context, AppWidgetManager.getInstance(context), intArrayOf(widgetId))
            }

            ACTION_COMPLETE_DUE -> {
                val widgetId = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID,
                )
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID)?.takeIf { it.isNotBlank() }
                    ?: return
                if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    DueWidgetActions.completeDue(
                        context,
                        itemId,
                        widgetId = widgetId,
                    )
                } else {
                    DueWidgetActions.completeDue(context, itemId)
                }
                updateAll(context)
            }
        }
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

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            update(
                context,
                manager,
                manager.getAppWidgetIds(
                    android.content.ComponentName(context, DueWidgetProvider::class.java),
                ),
            )
        }

        const val ACTION_SHUFFLE_QUOTE =
            "io.easycalendar.easy_calendar.widget.SHUFFLE_QUOTE"
        const val ACTION_COMPLETE_DUE =
            "io.easycalendar.easy_calendar.widget.COMPLETE_DUE"
        const val EXTRA_ITEM_ID = "extra_item_id"
    }
}

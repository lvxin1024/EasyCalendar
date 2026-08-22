package io.easycalendar.easy_calendar.widget

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

internal class WeekWidgetRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WeekWidgetProvider.updateAll(context)
        WeekWidgetRefreshScheduler.schedule(context)
    }
}

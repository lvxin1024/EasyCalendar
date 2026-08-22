package io.easycalendar.easy_calendar.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.appwidget.AppWidgetManager

internal object WeekWidgetRefreshScheduler {
    private const val ACTION_REFRESH = "io.easycalendar.easy_calendar.widget.REFRESH_WEEK_WIDGETS"
    private const val REQUEST_CODE = 42017
    private const val INTERVAL_MILLIS = 15 * 60 * 1000L

    fun schedule(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val widgetIds = manager.getAppWidgetIds(ComponentName(context, WeekWidgetProvider::class.java))
        if (widgetIds.isEmpty()) return
        val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = Intent(context, WeekWidgetRefreshReceiver::class.java).apply {
            action = ACTION_REFRESH
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val triggerAt = SystemClock.elapsedRealtime() + INTERVAL_MILLIS
        alarmManager.setInexactRepeating(
            AlarmManager.ELAPSED_REALTIME,
            triggerAt,
            INTERVAL_MILLIS,
            pendingIntent,
        )
    }
}

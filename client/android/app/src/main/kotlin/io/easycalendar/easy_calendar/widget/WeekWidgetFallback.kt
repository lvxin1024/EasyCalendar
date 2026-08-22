package io.easycalendar.easy_calendar.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.app.PendingIntent
import android.widget.RemoteViews
import io.easycalendar.easy_calendar.MainActivity
import io.easycalendar.easy_calendar.R

internal object WeekWidgetFallback {
    fun views(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_week_error)
        views.setOnClickPendingIntent(
            R.id.week_error_root,
            PendingIntent.getActivity(
                context,
                "easycalendar://today".hashCode(),
                Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = Uri.parse("easycalendar://today")
                    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        return views
    }
}

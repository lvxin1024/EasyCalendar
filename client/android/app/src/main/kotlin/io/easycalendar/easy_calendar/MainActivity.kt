package io.easycalendar.easy_calendar

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.easycalendar.easy_calendar.widget.EasyCalendarWidgetUpdater
import io.easycalendar.easy_calendar.widget.WidgetSnapshotStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var widgetChannel: MethodChannel? = null
    private var syncLifecycleChannel: MethodChannel? = null
    private var notificationChannel: MethodChannel? = null
    private var dartReady = false
    private var pendingWidgetUrl: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "writeSnapshot" -> {
                        val json = call.argument<String>("json")
                        if (json.isNullOrBlank()) {
                            result.error(
                                "invalid_widget_snapshot",
                                "Widget snapshot JSON is missing",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        if (!WidgetSnapshotStore.write(this, json)) {
                            result.error(
                                "widget_snapshot_write_failed",
                                "Widget snapshot could not be persisted",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        EasyCalendarWidgetUpdater.updateAll(this)
                        result.success(null)
                    }

                    "readyForWidgetLinks" -> {
                        dartReady = true
                        pendingWidgetUrl?.let(::sendWidgetUrl)
                        pendingWidgetUrl = null
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }
        syncLifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SYNC_LIFECYCLE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundSync" -> {
                        val intent = Intent(this, SyncForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "stopForegroundSync" -> {
                        stopService(Intent(this, SyncForegroundService::class.java))
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }
        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSettings" -> result.success(openNotificationSettings())
                    else -> result.notImplemented()
                }
            }
        }
        captureWidgetUrl(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureWidgetUrl(intent)
    }

    private fun captureWidgetUrl(intent: Intent?) {
        val url = intent?.data?.toString()?.takeIf { it.startsWith("easycalendar://") }
            ?: return
        if (dartReady) {
            sendWidgetUrl(url)
        } else {
            pendingWidgetUrl = url
        }
    }

    private fun sendWidgetUrl(url: String) {
        widgetChannel?.invokeMethod("openWidgetTarget", url)
    }

    private fun openNotificationSettings(): Boolean {
        val notificationIntent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }
        val appIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        return runCatching {
            startActivity(notificationIntent)
            true
        }.getOrElse {
            runCatching {
                startActivity(appIntent)
                true
            }.getOrDefault(false)
        }
    }

    private companion object {
        const val WIDGET_CHANNEL = "io.easycalendar/widget"
        const val SYNC_LIFECYCLE_CHANNEL = "io.easycalendar/sync_lifecycle"
        const val NOTIFICATION_CHANNEL = "io.easycalendar/notifications"
    }
}

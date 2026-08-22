package io.easycalendar.easy_calendar

import android.content.Intent
import io.easycalendar.easy_calendar.widget.EasyCalendarWidgetUpdater
import io.easycalendar.easy_calendar.widget.WidgetSnapshotStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var widgetChannel: MethodChannel? = null
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

    private companion object {
        const val WIDGET_CHANNEL = "io.easycalendar/widget"
    }
}

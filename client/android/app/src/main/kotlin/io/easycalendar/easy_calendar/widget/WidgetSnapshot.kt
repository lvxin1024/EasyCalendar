package io.easycalendar.easy_calendar.widget

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONException
import java.time.Instant
import java.time.ZoneId

private object WidgetSnapshotFields {
    const val SCHEMA_VERSION = "schema_version"
    const val GENERATED_AT = "generated_at"
    const val TIMEZONE = "timezone"
    const val CALENDAR_EVENTS = "calendar_events"
    const val WEEK_EVENTS = "week_events"
    const val TODAY_EVENTS = "today_events"
    const val UPCOMING_EVENTS = "upcoming_events"
    const val DUE_ITEMS = "due_items"
    const val QUOTES = "quotes"
}

internal data class WidgetItem(
    val id: String,
    val title: String,
    val type: String,
    val startAt: Instant?,
    val endAt: Instant?,
    val dueAt: Instant?,
    val allDay: Boolean,
)

internal data class WidgetSnapshot(
    val generatedAt: Instant?,
    val zoneId: ZoneId,
    val dueItems: List<WidgetItem>,
    val weekEvents: List<WidgetItem>,
    val calendarEvents: List<WidgetItem>,
    val quotes: List<String>,
) {
    companion object {
        fun decode(json: String): WidgetSnapshot {
            val root = JSONObject(json)
            require(root.optInt(WidgetSnapshotFields.SCHEMA_VERSION, -1) in 1..2) {
                "Unsupported widget snapshot schema"
            }
            val zoneId = runCatching {
                ZoneId.of(root.optString(WidgetSnapshotFields.TIMEZONE))
            }.getOrDefault(ZoneId.systemDefault())
            val weekEvents = root.optJSONArray(WidgetSnapshotFields.CALENDAR_EVENTS)
                ?: root.optJSONArray(WidgetSnapshotFields.WEEK_EVENTS)
                ?: mergeArrays(
                    root.optJSONArray(WidgetSnapshotFields.TODAY_EVENTS),
                    root.optJSONArray(WidgetSnapshotFields.UPCOMING_EVENTS),
                )
            return WidgetSnapshot(
                generatedAt = instantOrNull(root.stringOrNull(WidgetSnapshotFields.GENERATED_AT)),
                zoneId = zoneId,
                dueItems = decodeItems(root.optJSONArray(WidgetSnapshotFields.DUE_ITEMS)),
                weekEvents = decodeItems(weekEvents),
                calendarEvents = decodeItems(root.optJSONArray(WidgetSnapshotFields.CALENDAR_EVENTS)),
                quotes = decodeStrings(root.optJSONArray(WidgetSnapshotFields.QUOTES)),
            )
        }

        private fun decodeItems(array: JSONArray?): List<WidgetItem> {
            if (array == null) return emptyList()
            return buildList {
                for (index in 0 until array.length()) {
                    val value = array.optJSONObject(index) ?: continue
                    val id = value.stringOrNull("source_id")
                        ?: value.stringOrNull("id")
                        ?: continue
                    val title = value.stringOrNull("title") ?: continue
                    add(
                        WidgetItem(
                            id = id,
                            title = title,
                            type = value.optString("type"),
                            startAt = instantOrNull(value.stringOrNull("start_at")),
                            endAt = instantOrNull(value.stringOrNull("end_at")),
                            dueAt = instantOrNull(value.stringOrNull("due_at")),
                            allDay = value.optBoolean("all_day", false),
                        ),
                    )
                }
            }
        }

        private fun decodeStrings(array: JSONArray?): List<String> {
            if (array == null) return emptyList()
            return buildList {
                for (index in 0 until minOf(array.length(), 10)) {
                    array.optString(index).trim().takeIf(String::isNotEmpty)?.let(::add)
                }
            }
        }

        private fun mergeArrays(first: JSONArray?, second: JSONArray?): JSONArray {
            val result = JSONArray()
            for (array in listOfNotNull(first, second)) {
                for (index in 0 until array.length()) result.put(array.opt(index))
            }
            return result
        }

        private fun instantOrNull(value: String?): Instant? =
            value?.let { runCatching { Instant.parse(it) }.getOrNull() }

        private fun JSONObject.stringOrNull(name: String): String? =
            if (isNull(name)) null else optString(name).trim().takeIf(String::isNotEmpty)
    }
}

object WidgetSnapshotStore {
    private const val PREFERENCES = "easycalendar_widget"
    private const val SNAPSHOT_KEY = "snapshot_json"

    fun write(context: Context, json: String): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(SNAPSHOT_KEY, json)
            .commit()

    internal fun read(context: Context): WidgetSnapshot? {
        val json = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(SNAPSHOT_KEY, null)
            ?: return null
        return runCatching { WidgetSnapshot.decode(json) }.getOrNull()
    }

    internal fun quoteIndex(context: Context, widgetId: Int): Int =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getInt("quote_index_$widgetId", (widgetId * 1103515245).ushr(1))

    internal fun advanceQuote(context: Context, widgetId: Int) {
        val next = quoteIndex(context, widgetId) + 1
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putInt("quote_index_$widgetId", next)
            .apply()
    }

    internal fun removeDueItem(context: Context, itemId: String, widgetId: Int? = null): Boolean {
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val json = prefs.getString(SNAPSHOT_KEY, null) ?: return false
        return runCatching {
            val root = JSONObject(json)
            val source = root.optJSONArray(WidgetSnapshotFields.DUE_ITEMS) ?: return false
            val filtered = JSONArray()
            var changed = false
            for (index in 0 until source.length()) {
                val value = source.optJSONObject(index)
                val id = value?.stringOrNull("source_id")
                    ?: value?.stringOrNull("id")
                if (id == itemId) {
                    changed = true
                    continue
                }
                filtered.put(source.opt(index))
            }
            if (!changed) return false
            root.put(WidgetSnapshotFields.DUE_ITEMS, filtered)
            prefs.edit().putString(SNAPSHOT_KEY, root.toString()).commit()
        }.getOrDefault(false)
    }

    private fun JSONObject.stringOrNull(name: String): String? =
        if (isNull(name)) null else optString(name).trim().takeIf(String::isNotEmpty)
}

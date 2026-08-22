package io.easycalendar.easy_calendar.widget

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

internal data class WidgetItem(
    val id: String,
    val title: String,
    val type: String,
    val startAt: Instant?,
    val dueAt: Instant?,
    val allDay: Boolean,
)

internal data class WidgetSnapshot(
    val generatedAt: Instant?,
    val zoneId: ZoneId,
    val dueItems: List<WidgetItem>,
    val weekEvents: List<WidgetItem>,
) {
    companion object {
        fun decode(json: String): WidgetSnapshot {
            val root = JSONObject(json)
            require(root.optInt("schema_version", -1) == 1) {
                "Unsupported widget snapshot schema"
            }
            val zoneId = runCatching {
                ZoneId.of(root.optString("timezone"))
            }.getOrDefault(ZoneId.systemDefault())
            val weekEvents = root.optJSONArray("calendar_events")
                ?: root.optJSONArray("week_events")
                ?: mergeArrays(
                    root.optJSONArray("today_events"),
                    root.optJSONArray("upcoming_events"),
                )
            return WidgetSnapshot(
                generatedAt = instantOrNull(root.stringOrNull("generated_at")),
                zoneId = zoneId,
                dueItems = decodeItems(root.optJSONArray("due_items")),
                weekEvents = decodeItems(weekEvents),
            )
        }

        private fun decodeItems(array: JSONArray?): List<WidgetItem> {
            if (array == null) return emptyList()
            return buildList {
                for (index in 0 until array.length()) {
                    val value = array.optJSONObject(index) ?: continue
                    val id = value.stringOrNull("id") ?: continue
                    val title = value.stringOrNull("title") ?: continue
                    add(
                        WidgetItem(
                            id = id,
                            title = title,
                            type = value.optString("type"),
                            startAt = instantOrNull(value.stringOrNull("start_at")),
                            dueAt = instantOrNull(value.stringOrNull("due_at")),
                            allDay = value.optBoolean("all_day", false),
                        ),
                    )
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
}

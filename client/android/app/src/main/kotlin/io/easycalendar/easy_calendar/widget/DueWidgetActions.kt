package io.easycalendar.easy_calendar.widget

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.time.Instant
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal object DueWidgetActions {
    fun completeDue(context: Context, itemId: String, widgetId: Int? = null): Boolean {
        val snapshotRemoved = WidgetSnapshotStore.removeDueItem(context, itemId, widgetId)
        val completed = completeInDatabase(context, itemId)
        return snapshotRemoved || completed
    }

    private fun completeInDatabase(context: Context, itemId: String): Boolean {
        val databaseFile = resolveDatabaseFile(context) ?: return false
        val database = SQLiteDatabase.openDatabase(
            databaseFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        database.beginTransaction()
        try {
            val row = loadItemRow(database, itemId) ?: return false
            if (row.getString("item_type") != "task") return false
            val currentVersion = row.getInt("version")
            if (row.getString("status") == "done") {
                database.setTransactionSuccessful()
                return true
            }
            val now = Instant.now()
            val updatedAt = timeText(now)
            val values = ContentValues().apply {
                put("status", "done")
                put("updated_at", updatedAt)
                put("version", currentVersion + 1)
            }
            val count = database.update(
                "items",
                values,
                "id = ? AND version = ? AND deleted_at IS NULL",
                arrayOf(itemId, currentVersion.toString()),
            )
            if (count != 1) return false
            val updated = row.toMutableMap().apply {
                this["status"] = "done"
                this["updated_at"] = updatedAt
                this["version"] = currentVersion + 1
            }
            val changeId = "change_${UUID.randomUUID()}"
            val deviceId = loadDeviceId(database, context)
            val wrapped = RowMap(updated)
            val payload = itemPayload(wrapped)
            database.insertWithOnConflict(
                "outbox",
                null,
                outboxValues(changeId, deviceId, wrapped, payload),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            database.insertWithOnConflict(
                "sync_entity_heads",
                null,
                syncHeadValues(changeId, deviceId, wrapped, payload),
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            database.setTransactionSuccessful()
            return true
        } finally {
            database.endTransaction()
            database.close()
        }
    }

    private fun loadItemRow(database: SQLiteDatabase, itemId: String): RowMap? {
        database.rawQuery(
            """
            SELECT id, collection_id, item_type, title, body, start_at, end_at, due_at,
                   timezone, all_day, location, status, priority, reminder_enabled,
                   reminder_minutes, recurrence_json, tags_json, created_at, updated_at,
                   deleted_at, version
            FROM items
            WHERE id = ? AND deleted_at IS NULL
            LIMIT 1
            """.trimIndent(),
            arrayOf(itemId),
        ).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return RowMap(
                mapOf(
                    "id" to cursor.getString(0),
                    "collection_id" to cursor.getString(1),
                    "item_type" to cursor.getString(2),
                    "title" to cursor.getString(3),
                    "body" to cursor.getStringOrNull(4),
                    "start_at" to cursor.getStringOrNull(5),
                    "end_at" to cursor.getStringOrNull(6),
                    "due_at" to cursor.getStringOrNull(7),
                    "timezone" to cursor.getString(8),
                    "all_day" to cursor.getInt(9),
                    "location" to cursor.getStringOrNull(10),
                    "status" to cursor.getString(11),
                    "priority" to cursor.getIntOrNull(12),
                    "reminder_enabled" to cursor.getInt(13),
                    "reminder_minutes" to cursor.getInt(14),
                    "recurrence_json" to cursor.getStringOrNull(15),
                    "tags_json" to cursor.getString(16),
                    "created_at" to cursor.getString(17),
                    "updated_at" to cursor.getString(18),
                    "deleted_at" to cursor.getStringOrNull(19),
                    "version" to cursor.getInt(20),
                ),
            )
        }
    }

    private fun loadDeviceId(database: SQLiteDatabase, context: Context): String {
        database.rawQuery(
            "SELECT value FROM app_settings WHERE key = 'device_id' LIMIT 1",
            null,
        ).use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return context.packageName
    }

    private fun outboxValues(
        changeId: String,
        deviceId: String,
        row: RowMap,
        payload: Map<String, Any?>,
    ) = ContentValues().apply {
        put("change_id", changeId)
        put("device_id", deviceId)
        put("entity_type", "item")
        put("entity_id", row.getString("id"))
        put("operation", "update")
        put("entity_version", row.getInt("version"))
        put("payload_json", JSONObject(payload).toString())
        put("created_at", row.getString("updated_at"))
        put("retry_count", 0)
        put("last_error", null as String?)
        put("next_attempt_at", null as String?)
        put("permanent_failure", 0)
        put("sent_at", null as String?)
    }

    private fun syncHeadValues(
        changeId: String,
        deviceId: String,
        row: RowMap,
        payload: Map<String, Any?>,
    ) = ContentValues().apply {
        put("entity_type", "item")
        put("entity_id", row.getString("id"))
        put("change_id", changeId)
        put("device_id", deviceId)
        put("operation", "update")
        put("entity_version", row.getInt("version"))
        put("updated_at", row.getString("updated_at"))
        put("payload_json", JSONObject(payload).toString())
    }

    private fun itemPayload(row: RowMap): Map<String, Any?> = mapOf(
        "id" to row.getString("id"),
        "collection_id" to row.getString("collection_id"),
        "type" to row.getString("item_type"),
        "title" to row.getString("title"),
        "body" to row.getStringOrNull("body"),
        "start_at" to row.getStringOrNull("start_at"),
        "end_at" to row.getStringOrNull("end_at"),
        "due_at" to row.getStringOrNull("due_at"),
        "timezone" to row.getString("timezone"),
        "all_day" to (row.getInt("all_day") == 1),
        "location" to row.getStringOrNull("location"),
        "status" to row.getString("status"),
        "priority" to row.getIntOrNull("priority"),
        "recurrence" to row.getStringOrNull("recurrence_json")?.let { JSONObject(it) },
        "reminders" to if (row.getInt("reminder_enabled") == 1) {
            listOf(
                mapOf(
                    "id" to "${row.getString("id")}:reminder:0",
                    "item_id" to row.getString("id"),
                    "mode" to "relative",
                    "minutes_before" to row.getInt("reminder_minutes"),
                    "remind_at" to null,
                    "enabled" to true,
                ),
            )
        } else {
            emptyList<Map<String, Any?>>()
        },
        "created_at" to row.getString("created_at"),
        "updated_at" to row.getString("updated_at"),
        "deleted_at" to row.getStringOrNull("deleted_at"),
        "version" to row.getInt("version"),
        "tags" to runCatching {
            val array = JSONArray(row.getString("tags_json"))
            List(array.length()) { index -> array.optString(index) }
        }.getOrDefault(emptyList()),
    )

    private fun timeText(instant: Instant): String = instant.toString()

    private fun resolveDatabaseFile(context: Context): File? {
        val filesDir = context.filesDir
        val defaultFile = File(filesDir, "easycalendar.sqlite3")
        if (defaultFile.exists()) return defaultFile
        return filesDir.listFiles()
            ?.firstOrNull { file ->
                file.isFile && file.name.endsWith(".sqlite3") && !file.name.startsWith("easycalendar_")
            }
            ?: defaultFile.takeIf { it.parentFile?.exists() == true }
    }

    private fun Cursor.getStringOrNull(index: Int): String? =
        if (isNull(index)) null else getString(index)

    private fun Cursor.getIntOrNull(index: Int): Int? =
        if (isNull(index)) null else getInt(index)

    private class RowMap(private val values: Map<String, Any?>) {
        fun getString(name: String): String = values[name] as String
        fun getStringOrNull(name: String): String? = values[name] as String?
        fun getInt(name: String): Int = values[name] as Int
        fun getIntOrNull(name: String): Int? = values[name] as Int?
        operator fun get(name: String): Any? = values[name]
        fun toMutableMap(): MutableMap<String, Any?> = values.toMutableMap()
    }
}

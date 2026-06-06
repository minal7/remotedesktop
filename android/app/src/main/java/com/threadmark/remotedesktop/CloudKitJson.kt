package com.threadmark.remotedesktop

import org.json.JSONArray
import org.json.JSONObject

object CloudKitJson {
    fun stringField(value: String): JSONObject =
        JSONObject().put("value", value).put("type", "STRING")

    fun timestampField(valueMillis: Long): JSONObject =
        JSONObject().put("value", valueMillis).put("type", "TIMESTAMP")

    fun stringValue(fields: JSONObject, key: String): String? =
        fields.optJSONObject(key)?.opt("value")?.toString()

    fun longValue(fields: JSONObject, key: String): Long? {
        val value = fields.optJSONObject(key)?.opt("value") ?: return null
        return when (value) {
            is Number -> value.toLong()
            is String -> value.toLongOrNull()
            else -> null
        }
    }

    fun stringArrayValue(fields: JSONObject, key: String): List<String> {
        val array = fields.optJSONObject(key)?.optJSONArray("value") ?: return emptyList()
        return array.toStringList()
    }
}

fun JSONArray.toObjectList(): List<JSONObject> =
    buildList {
        for (i in 0 until length()) {
            optJSONObject(i)?.let(::add)
        }
    }

fun JSONArray.toStringList(): List<String> =
    buildList {
        for (i in 0 until length()) {
            val value = optString(i, "")
            if (value.isNotBlank()) add(value)
        }
    }

fun nowMillis(): Long = System.currentTimeMillis()

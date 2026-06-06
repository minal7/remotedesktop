package com.threadmark.remotedesktop

import org.json.JSONArray
import org.json.JSONObject

class IceConfigFetcher(private val cloudKit: CloudKitClient) {
    private var cached: IceConfig? = null

    suspend fun get(): IceConfig {
        cached?.let { return it }
        val fetched = fetchOrFallback()
        cached = fetched
        return fetched
    }

    fun reset() {
        cached = null
    }

    private suspend fun fetchOrFallback(): IceConfig {
        val body = JSONObject()
            .put("records", JSONArray().put(JSONObject().put("recordName", "default")))
        val value = runCatching {
            cloudKit.postAuthenticated("public", "records/lookup", body)
        }.getOrNull() ?: return IceConfig(Config.fallbackStunUrls)

        val record = value.optJSONArray("records")?.optJSONObject(0) ?: return IceConfig(Config.fallbackStunUrls)
        if (record.has("serverErrorCode")) return IceConfig(Config.fallbackStunUrls)
        val fields = record.optJSONObject("fields") ?: return IceConfig(Config.fallbackStunUrls)
        val stunUrls = CloudKitJson.stringArrayValue(fields, "stunURLs").ifEmpty {
            Config.fallbackStunUrls
        }
        return IceConfig(
            stunUrls = stunUrls,
            turnUrls = CloudKitJson.stringArrayValue(fields, "turnURLs"),
            turnUsername = CloudKitJson.stringValue(fields, "turnUsername"),
            turnCredential = CloudKitJson.stringValue(fields, "turnCredential"),
        )
    }
}

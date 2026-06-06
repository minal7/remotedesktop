package com.threadmark.remotedesktop

import android.content.Context
import java.util.UUID

class TokenStore(context: Context) {
    private val preferences = context.getSharedPreferences("cloudkit", Context.MODE_PRIVATE)

    var webAuthToken: String?
        get() = preferences.getString(KEY_WEB_AUTH_TOKEN, null)?.takeIf { it.isNotBlank() }
        set(value) {
            preferences.edit().apply {
                if (value.isNullOrBlank()) {
                    remove(KEY_WEB_AUTH_TOKEN)
                } else {
                    putString(KEY_WEB_AUTH_TOKEN, value)
                }
            }.apply()
        }

    val senderId: String
        get() {
            val existing = preferences.getString(KEY_SENDER_ID, null)
            if (!existing.isNullOrBlank()) return existing
            val created = "android-${UUID.randomUUID()}"
            preferences.edit().putString(KEY_SENDER_ID, created).apply()
            return created
        }

    fun clearLogin() {
        preferences.edit().remove(KEY_WEB_AUTH_TOKEN).apply()
    }

    private companion object {
        const val KEY_WEB_AUTH_TOKEN = "ck_web_auth_token"
        const val KEY_SENDER_ID = "sender_id"
    }
}

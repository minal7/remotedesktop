package com.threadmark.remotedesktop

import android.net.Uri
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

class CloudKitClient(private val tokenStore: TokenStore) {
    suspend fun currentUser(): String {
        val value = getAuthenticated("public", "users/caller")
        value.optString("userRecordName").takeIf { it.isNotBlank() }?.let { return it }
        val users = value.optJSONArray("users")
        val recordName = users
            ?.optJSONObject(0)
            ?.optString("userRecordName")
            .orEmpty()
        if (recordName.isNotBlank()) return recordName
        throw CloudKitException.MissingField("userRecordName")
    }

    suspend fun authenticationRedirectUrl(): String {
        return try {
            getUnauthenticated("public", "users/caller")
            throw CloudKitException.Server(
                "AUTHENTICATION_NOT_REQUIRED",
                "CloudKit unexpectedly allowed the request without Apple ID sign-in."
            )
        } catch (error: CloudKitException.AuthenticationRequired) {
            error.redirectUrl.ifBlank { throw CloudKitException.MissingField("redirectURL") }
        }
    }

    suspend fun getUnauthenticated(database: String, operationPath: String): JSONObject =
        send("GET", database, operationPath, null, WebAuth.Omit)

    suspend fun getAuthenticated(database: String, operationPath: String): JSONObject =
        send("GET", database, operationPath, null, WebAuth.Required)

    suspend fun postAuthenticated(
        database: String,
        operationPath: String,
        body: JSONObject,
    ): JSONObject = send("POST", database, operationPath, body, WebAuth.Required)

    suspend fun postAuthenticatedRetrying(
        database: String,
        operationPath: String,
        body: JSONObject,
    ): JSONObject {
        val delays = listOf(200L, 500L, 1_000L, 2_000L)
        delays.forEach { delayMillis ->
            try {
                return postAuthenticated(database, operationPath, body)
            } catch (error: CloudKitException) {
                if (!error.isTransient) throw error
                delay(delayMillis)
            } catch (error: IOException) {
                delay(delayMillis)
            }
        }
        return postAuthenticated(database, operationPath, body)
    }

    private suspend fun send(
        method: String,
        database: String,
        operationPath: String,
        body: JSONObject?,
        webAuth: WebAuth,
    ): JSONObject = withContext(Dispatchers.IO) {
        if (!Config.hasCloudKitApiToken) {
            throw CloudKitException.MissingApiToken
        }
        val token = when (webAuth) {
            WebAuth.Omit -> null
            WebAuth.Required -> tokenStore.webAuthToken
                ?: throw CloudKitException.MissingWebAuthToken
        }
        val connection = (URL(url(database, operationPath, token)).openConnection() as HttpURLConnection)
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = 20_000
        connection.setRequestProperty("Accept", "application/json")
        if (body != null) {
            val bytes = body.toString().toByteArray(StandardCharsets.UTF_8)
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Content-Length", bytes.size.toString())
            connection.outputStream.use { it.write(bytes) }
        }

        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
        val value = if (text.isBlank()) JSONObject() else JSONObject(text)
        storeRotatedWebAuthToken(value)

        cloudKitErrorFrom(value)?.let { error ->
            Log.w(
                TAG,
                "CloudKit $method ${Config.cloudKitEnvironment}/$database/$operationPath failed: ${error.logSummary()}"
            )
            clearTokenIfAuthFailed(error)
            throw error
        }
        if (status !in 200..299) {
            Log.w(
                TAG,
                "CloudKit $method ${Config.cloudKitEnvironment}/$database/$operationPath returned HTTP $status"
            )
            throw CloudKitException.HttpStatus(status, text)
        }
        Log.i(
            TAG,
            "CloudKit $method ${Config.cloudKitEnvironment}/$database/$operationPath succeeded"
        )
        value
    }

    private fun url(database: String, operationPath: String, webAuthToken: String?): String {
        val builder = Uri.Builder()
            .scheme("https")
            .authority("api.apple-cloudkit.com")
            .appendPath("database")
            .appendPath("1")
            .appendPath(Config.cloudKitContainer)
            .appendPath(Config.cloudKitEnvironment)
            .appendPath(database)
        operationPath
            .trim('/')
            .split('/')
            .filter { it.isNotBlank() }
            .forEach(builder::appendPath)
        builder.appendQueryParameter("ckAPIToken", Config.cloudKitApiToken)
        if (!webAuthToken.isNullOrBlank()) {
            builder.appendQueryParameter("ckWebAuthToken", webAuthToken)
        }
        return builder.build().toString()
    }

    private fun storeRotatedWebAuthToken(value: JSONObject) {
        val token = value.optString("ckWebAuthToken")
            .ifBlank { value.optString("webAuthToken") }
        if (token.isNotBlank()) {
            tokenStore.webAuthToken = token
        }
    }

    private fun clearTokenIfAuthFailed(error: CloudKitException) {
        if (error is CloudKitException.AuthenticationRequired ||
            error is CloudKitException.AuthenticationFailed
        ) {
            tokenStore.clearLogin()
        }
    }

    private fun cloudKitErrorFrom(value: JSONObject): CloudKitException? {
        val code = value.optString("serverErrorCode")
        if (code.isBlank()) return null
        val reason = value.optString("reason", "CloudKit request failed.")
        return when (code) {
            "AUTHENTICATION_REQUIRED" -> CloudKitException.AuthenticationRequired(
                value.optString("redirectURL")
            )
            "AUTHENTICATION_FAILED", "NOT_AUTHENTICATED" ->
                CloudKitException.AuthenticationFailed(reason)
            else -> CloudKitException.Server(code, reason)
        }
    }

    private enum class WebAuth { Omit, Required }

    private companion object {
        const val TAG = "RemoteDesktop.CloudKit"
    }
}

sealed class CloudKitException(message: String) : IOException(message) {
    object MissingApiToken : CloudKitException(
        "CloudKit API token is missing. Build with REMOTE_DESKTOP_CLOUDKIT_API_TOKEN."
    )

    object MissingWebAuthToken : CloudKitException("Apple ID sign-in is required.")
    data class AuthenticationRequired(val redirectUrl: String) :
        CloudKitException("Apple ID sign-in is required.")

    data class AuthenticationFailed(val reason: String) :
        CloudKitException("Apple ID sign-in failed or expired: $reason")

    data class Server(val code: String, val reason: String) :
        CloudKitException("CloudKit returned $code: $reason")

    data class HttpStatus(val status: Int, val body: String) :
        CloudKitException("CloudKit returned HTTP $status: $body")

    data class MissingField(val field: String) :
        CloudKitException("CloudKit response was missing $field")

    val isTransient: Boolean
        get() = this is Server && code in setOf(
            "TRY_AGAIN_LATER",
            "SERVICE_UNAVAILABLE",
            "ZONE_BUSY",
            "THROTTLED",
            "REQUEST_RATE_LIMITED",
        )

    fun logSummary(): String = when (this) {
        is MissingApiToken -> "missing API token"
        is MissingWebAuthToken -> "missing web auth token"
        is AuthenticationRequired -> "authentication required redirectHost=${runCatching { Uri.parse(redirectUrl).host }.getOrNull()}"
        is AuthenticationFailed -> "authentication failed"
        is Server -> "$code: $reason"
        is HttpStatus -> "HTTP $status"
        is MissingField -> "missing field $field"
    }
}

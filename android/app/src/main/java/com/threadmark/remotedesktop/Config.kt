package com.threadmark.remotedesktop

object Config {
    const val protocolVersion = 1
    const val enableHostAudio = true
    const val pollSeconds = 2L
    const val staleRecordSeconds = 300L

    val cloudKitContainer: String = BuildConfig.CLOUDKIT_CONTAINER
    val cloudKitEnvironment: String = BuildConfig.CLOUDKIT_ENV.ifBlank { "development" }
    val cloudKitApiToken: String = BuildConfig.CLOUDKIT_API_TOKEN
    val cloudKitAuthCallbackUrl: String = BuildConfig.CLOUDKIT_AUTH_CALLBACK_URL

    val hasCloudKitApiToken: Boolean
        get() = cloudKitApiToken.isNotBlank()

    val fallbackStunUrls = listOf(
        "stun:stun.l.google.com:19302",
        "stun:stun.cloudflare.com:3478",
    )
}

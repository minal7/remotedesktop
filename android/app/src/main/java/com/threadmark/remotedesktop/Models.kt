package com.threadmark.remotedesktop

data class LocalHostAdvertisement(
    val hostname: String,
    val code: String,
    val source: Source,
    val senderId: String? = null,
) {
    enum class Source { LocalNetwork, CloudKit }

    val id: String
        get() = senderId ?: "${source.name}|$hostname|$code"

    companion object {
        const val SERVICE_TYPE = "_remotedesktop._tcp."

        fun parse(serviceName: String): LocalHostAdvertisement? {
            val open = serviceName.lastIndexOf("[")
            val close = serviceName.lastIndexOf("]")
            if (open < 0 || close < 0 || open >= close) return null
            val hostname = serviceName.substring(0, open).trim()
            val code = serviceName.substring(open + 1, close)
            if (hostname.isBlank() || code.length != 6 || code.any { !it.isDigit() }) {
                return null
            }
            return LocalHostAdvertisement(hostname, code, Source.LocalNetwork)
        }
    }
}

data class HostHello(
    val app: String,
    val version: String,
    val hostname: String,
    val os: String,
    val audio: Boolean,
    val monitors: Int,
)

data class DisplayInfo(
    val width: Int,
    val height: Int,
    val scale: Double,
)

data class IceConfig(
    val stunUrls: List<String>,
    val turnUrls: List<String> = emptyList(),
    val turnUsername: String? = null,
    val turnCredential: String? = null,
)

enum class ScrollPhase(val wireValue: String) {
    Begin("begin"),
    Changed("changed"),
    End("end"),
    Momentum("momentum"),
}

enum class SoftModifier(
    val symbol: String,
    val hidUsage: Int,
    val mask: Int,
) {
    Cmd("⌘", 0xE3, 1 shl 3),
    Opt("⌥", 0xE2, 1 shl 2),
    Ctrl("⌃", 0xE0, 1 shl 1),
    Shift("⇧", 0xE1, 1 shl 0),
}

sealed class SessionState {
    object Idle : SessionState()
    object Connecting : SessionState()
    data class Connected(val hostName: String?) : SessionState()
    data class Ended(val reason: String) : SessionState()
}

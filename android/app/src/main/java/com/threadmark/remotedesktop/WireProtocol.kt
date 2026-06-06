package com.threadmark.remotedesktop

import android.os.Build
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

sealed class ControlMessage {
    data class Hello(val proto: Int) : ControlMessage()
    data class Pointer(val x: Int, val y: Int, val buttons: Int) : ControlMessage()
    data class Scroll(
        val x: Int,
        val y: Int,
        val dx: Int,
        val dy: Int,
        val phase: ScrollPhase,
    ) : ControlMessage()

    data class Key(val usage: Int, val down: Boolean, val modifiers: Int) : ControlMessage()
    data class Text(val text: String) : ControlMessage()
    data class Qos(val targetFps: Int, val maxBitrateKbps: Int, val prefer: String) : ControlMessage()
    data class Bye(val reason: String) : ControlMessage()

    fun encoded(seq: Long, tsMicros: Long): ByteBuffer {
        val obj = JSONObject()
            .put("s", seq)
            .put("ts", tsMicros)
        when (this) {
            is Hello -> obj
                .put("t", "hello")
                .put("proto", proto)
                .put(
                    "client",
                    JSONObject()
                        .put("app", "RemoteDesktop-Android")
                        .put("version", BuildConfig.VERSION_NAME)
                        .put("device", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
                        .put("osVersion", Build.VERSION.RELEASE),
                )

            is Pointer -> obj
                .put("t", "pointer")
                .put("x", x)
                .put("y", y)
                .put("buttons", buttons)

            is Scroll -> obj
                .put("t", "scroll")
                .put("x", x)
                .put("y", y)
                .put("dx", dx)
                .put("dy", dy)
                .put("phase", phase.wireValue)

            is Key -> obj
                .put("t", "key")
                .put("usage", usage)
                .put("down", down)
                .put("modifiers", modifiers)

            is Text -> obj
                .put("t", "text")
                .put("s2", text)

            is Qos -> obj
                .put("t", "qos")
                .put("targetFps", targetFps)
                .put("maxBitrateKbps", maxBitrateKbps)
                .put("prefer", prefer)

            is Bye -> obj
                .put("t", "bye")
                .put("reason", reason)
        }
        return ByteBuffer.wrap(obj.toString().toByteArray(StandardCharsets.UTF_8))
    }
}

sealed class HostMessage {
    data class HelloAck(val hello: HostHello) : HostMessage()
    data class Display(val display: DisplayInfo) : HostMessage()
    data class Bye(val reason: String) : HostMessage()

    companion object {
        fun decode(data: ByteBuffer): HostMessage? {
            val duplicate = data.slice()
            val bytes = ByteArray(duplicate.remaining())
            duplicate.get(bytes)
            val obj = runCatching {
                JSONObject(String(bytes, StandardCharsets.UTF_8))
            }.getOrNull() ?: return null

            return when (obj.optString("t")) {
                "hello_ack" -> {
                    val host = obj.optJSONObject("host") ?: JSONObject()
                    val caps = obj.optJSONObject("caps") ?: JSONObject()
                    HelloAck(
                        HostHello(
                            app = host.optString("app", "RemoteDesktop-Host"),
                            version = host.optString("version", "0.1.0"),
                            hostname = host.optString("hostname", "Computer"),
                            os = host.optString("os", "Desktop"),
                            audio = caps.optBoolean("audio", false),
                            monitors = caps.optInt("monitors", 0),
                        )
                    )
                }

                "display" -> Display(
                    DisplayInfo(
                        width = obj.optInt("w", 0),
                        height = obj.optInt("h", 0),
                        scale = obj.optDouble("scale", 1.0),
                    )
                )

                "bye" -> Bye(obj.optString("reason", "Disconnected"))
                else -> null
            }
        }
    }
}

fun monotonicMicros(): Long = System.nanoTime() / 1_000L

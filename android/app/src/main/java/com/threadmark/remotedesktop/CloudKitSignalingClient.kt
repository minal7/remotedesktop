package com.threadmark.remotedesktop

import org.json.JSONArray
import org.json.JSONObject

data class SignalingEnvelope(
    val role: Role,
    val kind: Kind,
    val payload: JSONObject,
    val tsSeconds: Long,
) {
    enum class Role(val wireValue: String) { Host("host"), Client("client") }
    enum class Kind(val wireValue: String) {
        Offer("offer"),
        Answer("answer"),
        Ice("ice"),
        Bye("bye");

        companion object {
            fun from(value: String): Kind? = entries.firstOrNull { it.wireValue == value }
        }
    }
}

class CloudKitSignalingClient(
    private val cloudKit: CloudKitClient,
    private val tokenStore: TokenStore,
    private val pairingCode: String,
    private val staleRecordSeconds: Long = Config.staleRecordSeconds,
) {
    private val senderId: String = tokenStore.senderId
    private val startedAtMillis = nowMillis()
    private var targetId: String? = null
    private val consumedRecordNames = linkedSetOf<String>()
    private val ownedRecordNames = linkedSetOf<String>()

    suspend fun claim() {
        cloudKit.currentUser()
        cleanup()
        targetId = resolveHostSenderId()
    }

    suspend fun send(envelope: SignalingEnvelope) {
        val target = targetId ?: throw CloudKitException.MissingField("targetID")
        val body = JSONObject()
            .put(
                "operations",
                JSONArray().put(
                    JSONObject()
                        .put("operationType", "create")
                        .put(
                            "record",
                            JSONObject()
                                .put("recordType", "WebRTCSignal")
                                .put(
                                    "fields",
                                    JSONObject()
                                        .put("senderID", CloudKitJson.stringField(senderId))
                                        .put("targetID", CloudKitJson.stringField(target))
                                        .put("pairingCode", CloudKitJson.stringField(pairingCode))
                                        .put("kind", CloudKitJson.stringField(envelope.kind.wireValue))
                                        .put("payload", CloudKitJson.stringField(envelope.payload.toString()))
                                        .put("createdAt", CloudKitJson.timestampField(nowMillis())),
                                ),
                        ),
                ),
            )
        val value = cloudKit.postAuthenticatedRetrying("private", "records/modify", body)
        recordOwnedNames(value)
    }

    suspend fun poll(): List<SignalingEnvelope> {
        val cutoff = nowMillis() - staleRecordSeconds * 1_000L
        val minCreatedAt = maxOf(cutoff, startedAtMillis)
        val body = JSONObject()
            .put("zoneID", JSONObject().put("zoneName", "_defaultZone"))
            .put("resultsLimit", 50)
            .put("numbersAsStrings", false)
            .put(
                "query",
                JSONObject()
                    .put("recordType", "WebRTCSignal")
                    .put(
                        "filterBy",
                        JSONArray()
                            .put(filter("targetID", "EQUALS", CloudKitJson.stringField(senderId)))
                            .put(
                                filter(
                                    "createdAt",
                                    "GREATER_THAN",
                                    CloudKitJson.timestampField(minCreatedAt),
                                )
                            ),
                    )
                    .put(
                        "sortBy",
                        JSONArray().put(
                            JSONObject()
                                .put("fieldName", "createdAt")
                                .put("ascending", true),
                        ),
                    ),
            )

        val value = try {
            cloudKit.postAuthenticated("private", "records/query", body)
        } catch (error: CloudKitException.Server) {
            if (error.code == "UNKNOWN_ITEM") return emptyList()
            throw error
        }

        return value
            .optJSONArray("records")
            ?.toObjectList()
            .orEmpty()
            .mapNotNull(::envelopeFromRecord)
    }

    suspend fun cleanup() {
        if (ownedRecordNames.isEmpty()) return
        val operations = JSONArray()
        ownedRecordNames.forEach { recordName ->
            operations.put(
                JSONObject()
                    .put("operationType", "forceDelete")
                    .put("record", JSONObject().put("recordName", recordName))
            )
        }
        runCatching {
            cloudKit.postAuthenticated(
                "private",
                "records/modify",
                JSONObject().put("operations", operations).put("atomic", false),
            )
        }
        ownedRecordNames.clear()
    }

    private suspend fun resolveHostSenderId(): String {
        val cutoff = nowMillis() - staleRecordSeconds * 1_000L
        val body = JSONObject()
            .put("zoneID", JSONObject().put("zoneName", "_defaultZone"))
            .put("resultsLimit", 10)
            .put("numbersAsStrings", false)
            .put(
                "query",
                JSONObject()
                    .put("recordType", "HostAdvertisement")
                    .put(
                        "filterBy",
                        JSONArray()
                            .put(filter("pairingCode", "EQUALS", CloudKitJson.stringField(pairingCode)))
                            .put(
                                filter(
                                    "createdAt",
                                    "GREATER_THAN",
                                    CloudKitJson.timestampField(cutoff),
                                )
                            ),
                    )
                    .put(
                        "sortBy",
                        JSONArray().put(
                            JSONObject()
                                .put("fieldName", "createdAt")
                                .put("ascending", false),
                        ),
                    ),
            )

        val value = try {
            cloudKit.postAuthenticated("private", "records/query", body)
        } catch (error: CloudKitException.Server) {
            if (error.code == "UNKNOWN_ITEM") {
                throw TransportException.BadPairingCode
            }
            throw error
        }

        val record = value.optJSONArray("records")?.toObjectList()?.firstOrNull {
            !it.has("serverErrorCode")
        } ?: throw TransportException.BadPairingCode
        val fields = record.optJSONObject("fields") ?: throw TransportException.BadPairingCode
        return CloudKitJson.stringValue(fields, "senderID") ?: throw TransportException.BadPairingCode
    }

    private fun envelopeFromRecord(record: JSONObject): SignalingEnvelope? {
        if (record.has("serverErrorCode")) return null
        val recordName = record.optString("recordName")
        if (recordName.isBlank() || !consumedRecordNames.add(recordName)) return null

        val fields = record.optJSONObject("fields") ?: return null
        val sender = CloudKitJson.stringValue(fields, "senderID") ?: return null
        if (targetId == null && sender != senderId) {
            targetId = sender
        }
        val kind = SignalingEnvelope.Kind.from(
            CloudKitJson.stringValue(fields, "kind") ?: return null
        ) ?: return null
        val payloadString = CloudKitJson.stringValue(fields, "payload") ?: "{}"
        val payload = runCatching { JSONObject(payloadString) }.getOrDefault(JSONObject())
        val createdAt = CloudKitJson.longValue(fields, "createdAt") ?: nowMillis()
        val role = if (sender == senderId) {
            SignalingEnvelope.Role.Client
        } else {
            SignalingEnvelope.Role.Host
        }
        return SignalingEnvelope(role, kind, payload, createdAt / 1_000L)
    }

    private fun recordOwnedNames(value: JSONObject) {
        value.optJSONArray("records")
            ?.toObjectList()
            .orEmpty()
            .forEach { record ->
                if (!record.has("serverErrorCode")) {
                    record.optString("recordName").takeIf { it.isNotBlank() }?.let(ownedRecordNames::add)
                }
            }
    }

    companion object {
        suspend fun fetchAvailableHostAdvertisements(
            cloudKit: CloudKitClient,
            staleRecordSeconds: Long = Config.staleRecordSeconds,
        ): List<LocalHostAdvertisement> {
            val cutoff = nowMillis() - staleRecordSeconds * 1_000L
            val body = JSONObject()
                .put("zoneID", JSONObject().put("zoneName", "_defaultZone"))
                .put("resultsLimit", 100)
                .put("numbersAsStrings", false)
                .put(
                    "query",
                    JSONObject()
                        .put("recordType", "HostAdvertisement")
                        .put(
                            "filterBy",
                            JSONArray().put(
                                filter(
                                    "createdAt",
                                    "GREATER_THAN",
                                    CloudKitJson.timestampField(cutoff),
                                )
                            ),
                        )
                        .put(
                            "sortBy",
                            JSONArray().put(
                                JSONObject()
                                    .put("fieldName", "createdAt")
                                    .put("ascending", false),
                            ),
                        ),
                )

            val value = try {
                cloudKit.postAuthenticated("private", "records/query", body)
            } catch (error: CloudKitException.Server) {
                if (error.code == "UNKNOWN_ITEM") return emptyList()
                throw error
            }

            val newestBySender = linkedMapOf<String, Pair<LocalHostAdvertisement, Long>>()
            value.optJSONArray("records")
                ?.toObjectList()
                .orEmpty()
                .forEach { record ->
                    if (record.has("serverErrorCode")) return@forEach
                    val fields = record.optJSONObject("fields") ?: return@forEach
                    val sender = CloudKitJson.stringValue(fields, "senderID") ?: return@forEach
                    val host = CloudKitJson.stringValue(fields, "hostName") ?: return@forEach
                    val code = CloudKitJson.stringValue(fields, "pairingCode") ?: return@forEach
                    val updated = CloudKitJson.longValue(fields, "createdAt") ?: 0L
                    if (host.isBlank() || code.length != 6 || code.any { !it.isDigit() }) return@forEach
                    val existing = newestBySender[sender]
                    if (existing == null || existing.second < updated) {
                        newestBySender[sender] = LocalHostAdvertisement(
                            hostname = host,
                            code = code,
                            source = LocalHostAdvertisement.Source.CloudKit,
                            senderId = sender,
                        ) to updated
                    }
                }
            return newestBySender.values
                .map { it.first }
                .sortedWith(
                    compareBy<LocalHostAdvertisement> { it.hostname.lowercase() }
                        .thenBy { it.code }
                )
        }

        private fun filter(fieldName: String, comparator: String, value: JSONObject): JSONObject =
            JSONObject()
                .put("fieldName", fieldName)
                .put("comparator", comparator)
                .put("fieldValue", value)
    }
}

sealed class TransportException(message: String) : Exception(message) {
    object BadPairingCode : TransportException(
        "No computer is advertising that pairing code. Check the code on your host and make sure both devices are signed into the same iCloud account."
    )

    data class NegotiationFailed(val reason: String) :
        TransportException("Connection failed: $reason")
}

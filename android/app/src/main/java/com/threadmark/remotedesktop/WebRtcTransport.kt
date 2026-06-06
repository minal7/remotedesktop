package com.threadmark.remotedesktop

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

class WebRtcTransport(
    private val context: Context,
    private val cloudKit: CloudKitClient,
    private val tokenStore: TokenStore,
    private val scope: CoroutineScope,
    private val onHostHello: (HostHello) -> Unit,
    private val onDisplay: (DisplayInfo) -> Unit,
    private val onDisconnect: (String) -> Unit,
) {
    private val eglBase = EglBase.create()
    private val factory: PeerConnectionFactory
    private val iceConfigFetcher = IceConfigFetcher(cloudKit)
    private var signaling: CloudKitSignalingClient? = null
    private var peerConnection: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var remoteVideoTrack: VideoTrack? = null
    private var remoteAudioTrack: AudioTrack? = null
    private var renderer: SurfaceViewRenderer? = null
    private var pollJob: Job? = null
    private var iceDeadlineJob: Job? = null
    private var recoveryJob: Job? = null
    private var seq = 0L
    private var sentHello = false
    private var answerApplied = false
    private var connectedOnce = false
    private var isClosing = false
    private var didReportDisconnect = false
    private val pendingRemoteIce = mutableListOf<IceCandidate>()

    val eglContext: EglBase.Context
        get() = eglBase.eglBaseContext

    init {
        WebRtcRuntime.initialize(context.applicationContext)
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory()
    }

    suspend fun connect(pairingCode: String) {
        close(reason = "reconnect", notifyRemote = false)
        isClosing = false
        didReportDisconnect = false
        connectedOnce = false
        sentHello = false
        answerApplied = false
        pendingRemoteIce.clear()

        val signaling = CloudKitSignalingClient(cloudKit, tokenStore, pairingCode)
        this.signaling = signaling
        signaling.claim()

        iceConfigFetcher.reset()
        val iceConfig = iceConfigFetcher.get()
        val peerConnection = makePeerConnection(iceConfig)
        this.peerConnection = peerConnection
        peerConnection.setAudioPlayout(Config.enableHostAudio)
        if (Config.enableHostAudio) {
            peerConnection.addTransceiver(
                MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
            )
        }
        peerConnection.addTransceiver(
            MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
        )

        val channelInit = DataChannel.Init().apply {
            ordered = true
            negotiated = false
        }
        dataChannel = peerConnection.createDataChannel("control", channelInit)?.also(::registerDataChannel)

        val offer = createOffer(peerConnection)
        setLocalDescription(peerConnection, offer)
        signaling.send(
            SignalingEnvelope(
                role = SignalingEnvelope.Role.Client,
                kind = SignalingEnvelope.Kind.Offer,
                payload = JSONObject()
                    .put("client", android.os.Build.MODEL ?: "Android")
                    .put("sdp", offer.description)
                    .put("sdpType", "offer"),
                tsSeconds = nowMillis() / 1_000L,
            )
        )

        pollJob = scope.launch {
            pollLoop()
        }
        iceDeadlineJob = scope.launch {
            delay(25_000L)
            if (!isClosing && !connectedOnce) {
                finishDisconnect("Can't reach your computer. Try putting both devices on the same Wi-Fi.")
            }
        }
    }

    fun attachVideoRenderer(renderer: SurfaceViewRenderer) {
        this.renderer = renderer
        remoteVideoTrack?.addSink(renderer)
    }

    fun detachVideoRenderer(renderer: SurfaceViewRenderer) {
        remoteVideoTrack?.removeSink(renderer)
        if (this.renderer === renderer) {
            this.renderer = null
        }
    }

    fun send(message: ControlMessage) {
        val channel = dataChannel ?: return
        if (channel.state() != DataChannel.State.OPEN) return
        seq = (seq + 1) and 0xFFFF_FFFFL
        channel.send(DataChannel.Buffer(message.encoded(seq, monotonicMicros()), false))
    }

    fun disconnect() {
        close(reason = "user", notifyRemote = true)
        onDisconnect("Disconnected")
    }

    fun dispose() {
        close(reason = "dispose", notifyRemote = false)
        factory.dispose()
        eglBase.release()
    }

    private fun makePeerConnection(iceConfig: IceConfig): PeerConnection {
        val servers = mutableListOf<PeerConnection.IceServer>()
        iceConfig.stunUrls.forEach { servers += PeerConnection.IceServer.builder(it).createIceServer() }
        if (iceConfig.turnUrls.isNotEmpty() &&
            !iceConfig.turnUsername.isNullOrBlank() &&
            !iceConfig.turnCredential.isNullOrBlank()
        ) {
            servers += PeerConnection.IceServer.builder(iceConfig.turnUrls)
                .setUsername(iceConfig.turnUsername)
                .setPassword(iceConfig.turnCredential)
                .createIceServer()
        }

        val configuration = PeerConnection.RTCConfiguration(servers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        return factory.createPeerConnection(configuration, observer)
            ?: throw TransportException.NegotiationFailed("Couldn't create the peer connection.")
    }

    private suspend fun pollLoop() {
        while (scope.coroutineContext.isActive && !isClosing) {
            val envelopes = try {
                signaling?.poll().orEmpty()
            } catch (error: Throwable) {
                finishDisconnect("The WebRTC signaling loop ended unexpectedly: ${error.message ?: error}")
                return
            }
            for (envelope in envelopes) {
                when (envelope.kind) {
                    SignalingEnvelope.Kind.Answer -> {
                        if (answerApplied) continue
                        val sdp = envelope.payload.optString("sdp")
                        if (sdp.isBlank()) continue
                        setRemoteDescription(
                            peerConnection,
                            SessionDescription(SessionDescription.Type.ANSWER, sdp),
                        )
                        answerApplied = true
                        flushPendingRemoteIce()
                    }

                    SignalingEnvelope.Kind.Ice -> {
                        iceCandidateFrom(envelope.payload)?.let { handleRemoteIce(it) }
                    }

                    SignalingEnvelope.Kind.Bye -> {
                        finishDisconnect(envelope.payload.optString("reason", "Disconnected"))
                        return
                    }

                    SignalingEnvelope.Kind.Offer -> Unit
                }
            }
            delay(Config.pollSeconds * 1_000L)
        }
    }

    private fun registerDataChannel(channel: DataChannel) {
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) = Unit

            override fun onStateChange() {
                sendHelloIfPossible()
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val message = HostMessage.decode(buffer.data) ?: return
                scope.launch(Dispatchers.Main) {
                    when (message) {
                        is HostMessage.HelloAck -> onHostHello(message.hello)
                        is HostMessage.Display -> onDisplay(message.display)
                        is HostMessage.Bye -> finishDisconnect(message.reason)
                    }
                }
            }
        })
        sendHelloIfPossible()
    }

    private fun sendHelloIfPossible() {
        val channel = dataChannel ?: return
        if (sentHello || channel.state() != DataChannel.State.OPEN) return
        sentHello = true
        channel.send(
            DataChannel.Buffer(
                ControlMessage.Hello(Config.protocolVersion).encoded(0, monotonicMicros()),
                false,
            )
        )
    }

    private fun handleRemoteIce(candidate: IceCandidate) {
        if (!answerApplied) {
            pendingRemoteIce += candidate
            return
        }
        addRemoteIceCandidate(candidate)
    }

    private fun flushPendingRemoteIce() {
        val candidates = pendingRemoteIce.toList()
        pendingRemoteIce.clear()
        candidates.forEach(::addRemoteIceCandidate)
    }

    private fun iceCandidateFrom(payload: JSONObject): IceCandidate? {
        val sdp = payload.optString("candidate")
        if (sdp.isBlank()) return null
        return IceCandidate(
            payload.optString("sdpMid", ""),
            payload.optString("sdpMLineIndex").toIntOrNull() ?: 0,
            sdp,
        )
    }

    private fun addRemoteIceCandidate(candidate: IceCandidate) {
        try {
            peerConnection?.addIceCandidate(candidate)
        } catch (error: Throwable) {
            Log.w("RemoteDesktop.WebRtc", "Failed to add remote ICE candidate", error)
            finishDisconnect("Couldn't connect to the computer. Try again.")
        }
    }

    private fun candidatePayload(candidate: IceCandidate): JSONObject =
        JSONObject()
            .put("candidate", candidate.sdp)
            .put("sdpMid", candidate.sdpMid ?: "")
            .put("sdpMLineIndex", candidate.sdpMLineIndex.toString())

    private fun adoptRemoteVideoTrack(track: VideoTrack) {
        remoteVideoTrack = track
        renderer?.let(track::addSink)
    }

    private fun adoptRemoteAudioTrack(track: AudioTrack) {
        if (!Config.enableHostAudio) return
        remoteAudioTrack?.setEnabled(false)
        remoteAudioTrack = track
        track.setEnabled(true)
        track.setVolume(1.0)
    }

    private fun close(reason: String, notifyRemote: Boolean) {
        isClosing = true
        if (notifyRemote) {
            send(ControlMessage.Bye(reason))
        }
        pollJob?.cancel()
        pollJob = null
        iceDeadlineJob?.cancel()
        iceDeadlineJob = null
        recoveryJob?.cancel()
        recoveryJob = null
        connectedOnce = false
        renderer?.let { remoteVideoTrack?.removeSink(it) }
        remoteAudioTrack?.setEnabled(false)
        remoteVideoTrack = null
        remoteAudioTrack = null
        dataChannel?.close()
        dataChannel?.dispose()
        dataChannel = null
        peerConnection?.close()
        peerConnection?.dispose()
        peerConnection = null
        val signalingToClean = signaling
        signaling = null
        sentHello = false
        answerApplied = false
        pendingRemoteIce.clear()
        if (signalingToClean != null) {
            scope.launch { signalingToClean.cleanup() }
        }
    }

    private fun finishDisconnect(reason: String) {
        if (didReportDisconnect) return
        didReportDisconnect = true
        close(reason = reason, notifyRemote = false)
        scope.launch(Dispatchers.Main) {
            onDisconnect(reason)
        }
    }

    private suspend fun createOffer(peerConnection: PeerConnection): SessionDescription =
        suspendCoroutine { continuation ->
            peerConnection.createOffer(
                object : SdpObserverAdapter() {
                    override fun onCreateSuccess(description: SessionDescription) {
                        continuation.resume(description)
                    }

                    override fun onCreateFailure(error: String) {
                        continuation.resumeWithException(TransportException.NegotiationFailed(error))
                    }
                },
                MediaConstraints(),
            )
        }

    private suspend fun setLocalDescription(
        peerConnection: PeerConnection,
        description: SessionDescription,
    ) = suspendCoroutine<Unit> { continuation ->
        peerConnection.setLocalDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() = continuation.resume(Unit)
                override fun onSetFailure(error: String) {
                    continuation.resumeWithException(TransportException.NegotiationFailed(error))
                }
            },
            description,
        )
    }

    private suspend fun setRemoteDescription(
        peerConnection: PeerConnection?,
        description: SessionDescription,
    ) = suspendCoroutine<Unit> { continuation ->
        val pc = peerConnection
        if (pc == null) {
            continuation.resumeWithException(TransportException.NegotiationFailed("Peer connection was released."))
            return@suspendCoroutine
        }
        pc.setRemoteDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() = continuation.resume(Unit)
                override fun onSetFailure(error: String) {
                    continuation.resumeWithException(TransportException.NegotiationFailed(error))
                }
            },
            description,
        )
    }

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) {
            stream.videoTracks.firstOrNull()?.let(::adoptRemoteVideoTrack)
        }

        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onRenegotiationNeeded() = Unit

        override fun onDataChannel(channel: DataChannel) {
            dataChannel = channel
            registerDataChannel(channel)
        }

        override fun onIceCandidate(candidate: IceCandidate) {
            scope.launch {
                runCatching {
                    signaling?.send(
                        SignalingEnvelope(
                            role = SignalingEnvelope.Role.Client,
                            kind = SignalingEnvelope.Kind.Ice,
                            payload = candidatePayload(candidate),
                            tsSeconds = nowMillis() / 1_000L,
                        )
                    )
                }
            }
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            when (state) {
                PeerConnection.IceConnectionState.FAILED -> {
                    val reason = if (connectedOnce) {
                        "The peer connection failed."
                    } else {
                        "Can't reach your computer. Try putting both devices on the same Wi-Fi."
                    }
                    finishDisconnect(reason)
                }

                PeerConnection.IceConnectionState.DISCONNECTED -> {
                    if (!connectedOnce || recoveryJob != null) return
                    recoveryJob = scope.launch {
                        delay(12_000L)
                        if (!isClosing && connectedOnce) {
                            finishDisconnect("The peer connection did not recover.")
                        }
                    }
                }

                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> {
                    connectedOnce = true
                    iceDeadlineJob?.cancel()
                    iceDeadlineJob = null
                    recoveryJob?.cancel()
                    recoveryJob = null
                }

                PeerConnection.IceConnectionState.CLOSED -> {
                    if (!isClosing) finishDisconnect("The peer connection closed.")
                }

                else -> Unit
            }
        }

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
            when (newState) {
                PeerConnection.PeerConnectionState.CONNECTED -> {
                    connectedOnce = true
                    iceDeadlineJob?.cancel()
                    iceDeadlineJob = null
                    recoveryJob?.cancel()
                    recoveryJob = null
                }

                PeerConnection.PeerConnectionState.FAILED -> finishDisconnect("The peer connection failed.")
                PeerConnection.PeerConnectionState.CLOSED -> {
                    if (!isClosing) finishDisconnect("The peer connection closed.")
                }

                else -> Unit
            }
        }

        override fun onAddTrack(receiver: RtpReceiver, mediaStreams: Array<out MediaStream>) {
            when (val track = receiver.track()) {
                is VideoTrack -> adoptRemoteVideoTrack(track)
                is AudioTrack -> adoptRemoteAudioTrack(track)
            }
        }

        override fun onTrack(transceiver: RtpTransceiver) {
            when (val track = transceiver.receiver.track()) {
                is VideoTrack -> adoptRemoteVideoTrack(track)
                is AudioTrack -> adoptRemoteAudioTrack(track)
            }
        }
    }
}

private open class SdpObserverAdapter : SdpObserver {
    override fun onCreateSuccess(description: SessionDescription) = Unit
    override fun onSetSuccess() = Unit
    override fun onCreateFailure(error: String) = Unit
    override fun onSetFailure(error: String) = Unit
}

private object WebRtcRuntime {
    private val initialized = AtomicBoolean(false)

    fun initialize(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions
                .builder(context)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )
    }
}

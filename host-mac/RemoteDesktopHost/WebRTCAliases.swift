import LiveKitWebRTC

typealias RTCConfiguration = LKRTCConfiguration
typealias RTCAudioDeviceModule = LKRTCAudioDeviceModule
typealias RTCAudioDeviceModuleDelegate = LKRTCAudioDeviceModuleDelegate
typealias RTCAudioDeviceModuleType = LKRTCAudioDeviceModuleType
typealias RTCAudioEngineAvailability = LKRTCAudioEngineAvailability
typealias RTCSpeechActivityEvent = LKRTCSpeechActivityEvent
typealias RTCAudioSource = LKRTCAudioSource
typealias RTCAudioTrack = LKRTCAudioTrack
typealias RTCConnectionState = LKRTCPeerConnectionState
typealias RTCCVPixelBuffer = LKRTCCVPixelBuffer
typealias RTCDataBuffer = LKRTCDataBuffer
typealias RTCDataChannel = LKRTCDataChannel
typealias RTCDataChannelConfiguration = LKRTCDataChannelConfiguration
typealias RTCDataChannelDelegate = LKRTCDataChannelDelegate
typealias RTCDefaultVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory
typealias RTCDefaultVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory
typealias RTCIceCandidate = LKRTCIceCandidate
typealias RTCIceConnectionState = LKRTCIceConnectionState
typealias RTCIceGatheringState = LKRTCIceGatheringState
typealias RTCIceServer = LKRTCIceServer
typealias RTCMediaConstraints = LKRTCMediaConstraints
typealias RTCMediaStream = LKRTCMediaStream
typealias RTCMediaStreamTrack = LKRTCMediaStreamTrack
typealias RTCPeerConnection = LKRTCPeerConnection
typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
typealias RTCRtpMediaType = LKRTCRtpMediaType
typealias RTCRtpReceiver = LKRTCRtpReceiver
typealias RTCRtpSender = LKRTCRtpSender
typealias RTCRtpTransceiver = LKRTCRtpTransceiver
typealias RTCRtpTransceiverDirection = LKRTCRtpTransceiverDirection
typealias RTCRtpTransceiverInit = LKRTCRtpTransceiverInit
typealias RTCSessionDescription = LKRTCSessionDescription
typealias RTCSignalingState = LKRTCSignalingState
typealias RTCVideoCapturer = LKRTCVideoCapturer
typealias RTCVideoFrame = LKRTCVideoFrame
typealias RTCVideoRotation = LKRTCVideoRotation
typealias RTCVideoSource = LKRTCVideoSource
typealias RTCVideoTrack = LKRTCVideoTrack

@discardableResult
func RTCInitializeSSL() -> Bool {
    LKRTCInitializeSSL()
}

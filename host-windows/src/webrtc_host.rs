//! The live WebRTC peer session. Mirrors
//! `host-mac/RemoteDesktopHost/HostPeerSession.swift`:
//!
//! - accept the client's SDP offer, add a send-only H.264 screen track
//!   and a send-only Opus system-audio track, answer;
//! - trickle ICE both ways through CloudKit signaling;
//! - serve the `control` data channel: `hello` → `hello_ack`+`display`,
//!   then route pointer/scroll/key/text into the input injector.
//!
//! Encoders are CPU-bound and OpenH264's encoder is not `Send`, so each
//! lives on its own OS thread fed by the capture channels; small async
//! tasks pump the encoded bitstream onto the WebRTC tracks.

use crate::capture::{self, LatestFrameReceiver};
use crate::input::InputInjector;
use crate::media::{AudioEncoder, VideoEncoder, OPUS_FRAME_INTERLEAVED};
use crate::protocol::{self, ClientMessage, DisplayInfo, HostInfo, PROTOCOL_VERSION};
use crate::signaling::{Kind, Role, SignalingEnvelope};
use anyhow::{Context, Result};
use bytes::Bytes;
use serde_json::{Map, Value};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::Receiver as StdReceiver;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::{channel, unbounded_channel, UnboundedSender};
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;
use tracing::{error, info, warn};
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264, MIME_TYPE_OPUS};
use webrtc::api::setting_engine::SettingEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::media::Sample;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtcp::payload_feedbacks::full_intra_request::FullIntraRequest;
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::rtp_transceiver::rtp_sender::RTCRtpSender;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::RTCRtpTransceiverInit;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;

const VIDEO_BITRATE_BPS: u32 = 8_000_000;
const TARGET_FPS: f32 = 60.0;

/// How long the connection may sit in ICE `disconnected` before we tear
/// the session down and return to advertising. webrtc-rs only emits
/// `failed` after its default failed-timeout of further silence, so
/// without this grace timer an abruptly-gone iOS client (app killed,
/// Wi-Fi dropped — no `bye` sent) would keep the host "Connected" for
/// ~30s.
const DISCONNECT_GRACE: Duration = Duration::from_secs(3);

struct EncodedFrame {
    data: Vec<u8>,
    /// Captured at the moment the encoder finished this frame. Used by
    /// the writer to derive the RTP duration from real wall-clock time
    /// rather than a fixed `1/TARGET_FPS`.
    captured_at: Instant,
}

pub struct WebRtcHost {
    pc: Arc<RTCPeerConnection>,
    closed: Arc<AtomicBool>,
    capture_stop: Mutex<Option<capture::StopHandle>>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl WebRtcHost {
    /// Builds the peer connection, answers `offer_sdp`, and starts
    /// capture. The answer and all local ICE candidates are pushed to
    /// `outbound` (the main loop forwards them over CloudKit, in order).
    /// `ended` is notified once when the session is finished.
    pub async fn start(
        offer_sdp: String,
        ice_servers: Vec<String>,
        outbound: UnboundedSender<SignalingEnvelope>,
        ended: Arc<Notify>,
        injector: InputInjector,
        host_info: HostInfo,
    ) -> Result<Arc<Self>> {
        let mut media_engine = MediaEngine::default();
        media_engine
            .register_default_codecs()
            .context("register WebRTC codecs")?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)
            .context("register WebRTC interceptors")?;
        // Mirror the macOS host: no custom ICE timeouts, no candidate
        // filtering, no forced DTLS role. webrtc-rs's defaults answer as
        // DTLS *client* (`setup:active`, the RFC 5763 recommendation), so
        // the host drives the handshake against the iOS DTLS server just
        // like libwebrtc does on the Mac. The defaults' generous
        // failed-timeout also tolerates candidates that trickle in slowly
        // over CloudKit signaling.
        let setting_engine = SettingEngine::default();
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();

        let config = RTCConfiguration {
            ice_servers: vec![RTCIceServer {
                urls: ice_servers,
                ..Default::default()
            }],
            ..Default::default()
        };
        let pc = Arc::new(
            api.new_peer_connection(config)
                .await
                .context("create peer connection")?,
        );

        let video_track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_H264.to_owned(),
                ..Default::default()
            },
            "screen".to_owned(),
            "remote-desktop".to_owned(),
        ));
        let audio_track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_OPUS.to_owned(),
                ..Default::default()
            },
            "system-audio".to_owned(),
            "remote-desktop".to_owned(),
        ));

        // Create the send-only transceivers *before* applying the
        // client's offer. webrtc-rs's m-line matcher
        // (`satisfy_type_and_direction`) pairs each remote `recvonly`
        // audio/video section with a pre-existing local `sendonly`
        // transceiver of the same kind. If we instead set the remote
        // description first and `add_track` after, webrtc-rs leaves the
        // real m-lines `recvonly` (no media ever flows) and appends
        // unmatched `sendrecv` transceivers with no answer section —
        // which is why screen + audio were dead while the data channel
        // (its own m-line) still worked.
        let video_sender = add_send_transceiver(&pc, "video", Arc::clone(&video_track))
            .await
            .context("add video transceiver")?;
        let _audio_sender = add_send_transceiver(&pc, "audio", Arc::clone(&audio_track))
            .await
            .context("add audio transceiver")?;

        // Set by the RTCP reader task on PLI/FIR and consumed by the
        // video encoder thread to flag the next frame as an IDR.
        let keyframe_request = Arc::new(AtomicBool::new(false));

        pc.set_remote_description(
            RTCSessionDescription::offer(offer_sdp).context("parse client offer")?,
        )
        .await
        .context("set remote description")?;

        let closed = Arc::new(AtomicBool::new(false));

        // Trickle local ICE → CloudKit.
        {
            let outbound = outbound.clone();
            pc.on_ice_candidate(Box::new(move |candidate| {
                let outbound = outbound.clone();
                Box::pin(async move {
                    let Some(candidate) = candidate else { return };
                    match candidate.to_json() {
                        Ok(init) => {
                            let _ = outbound.send(ice_envelope(&init));
                        }
                        Err(error) => {
                            warn!("couldn't serialize local ICE candidate: {error}")
                        }
                    }
                })
            }));
        }

        // Connection-state changes → end the session (auto-restart in
        // the main loop). `disconnected` can self-recover from a brief
        // blip, so we give it `DISCONNECT_GRACE` to come back before
        // tearing down; `failed`/`closed` tear down immediately. The
        // generation counter cancels a pending grace timer the moment a
        // newer state transition arrives, so a recovered peer is never
        // killed by a stale timer.
        let connection_generation = Arc::new(AtomicU64::new(0));
        // Fired once when the peer connection first reaches `Connected`
        // (DTLS established). Capture + the CPU-heavy software H.264
        // encoder hang off this so the encoder doesn't run flat-out
        // during the DTLS handshake and starve the async runtime driving
        // it. On Windows the OpenH264 encoder starting the instant the
        // offer arrived was enough to keep the handshake from completing —
        // especially over slower production CloudKit signaling, where ICE
        // takes several seconds to connect, giving the encoder time to peg
        // the machine before DTLS even runs. The macOS host uses a
        // hardware encoder and never hit this.
        let connected = Arc::new(Notify::new());
        {
            let ended = ended.clone();
            let closed = closed.clone();
            let connection_generation = connection_generation.clone();
            let connected = connected.clone();
            pc.on_peer_connection_state_change(Box::new(move |state| {
                let ended = ended.clone();
                let closed = closed.clone();
                let connection_generation = connection_generation.clone();
                let connected = connected.clone();
                Box::pin(async move {
                    info!("peer connection state → {state:?}");
                    match state {
                        RTCPeerConnectionState::Connected => {
                            // Supersede any in-flight disconnect grace timer.
                            connection_generation.fetch_add(1, Ordering::SeqCst);
                            // Release the deferred capture/encode pipeline.
                            connected.notify_one();
                        }
                        RTCPeerConnectionState::Disconnected => {
                            warn!(
                                "peer connection disconnected (waiting {DISCONNECT_GRACE:?} for recovery)"
                            );
                            let generation =
                                connection_generation.fetch_add(1, Ordering::SeqCst) + 1;
                            let ended = ended.clone();
                            let closed = closed.clone();
                            let connection_generation = connection_generation.clone();
                            tokio::spawn(async move {
                                tokio::time::sleep(DISCONNECT_GRACE).await;
                                let superseded = connection_generation.load(Ordering::SeqCst)
                                    != generation;
                                if !superseded && !closed.swap(true, Ordering::SeqCst) {
                                    warn!("peer still disconnected after grace — ending session");
                                    ended.notify_one();
                                }
                            });
                        }
                        RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed => {
                            connection_generation.fetch_add(1, Ordering::SeqCst);
                            if !closed.swap(true, Ordering::SeqCst) {
                                ended.notify_one();
                            }
                        }
                        _ => {}
                    }
                })
            }));
        }

        // The client creates the reliable-ordered `control` channel; we
        // receive it here and serve the protocol over it.
        {
            let injector = injector.clone();
            let ended = ended.clone();
            let closed = closed.clone();
            let host_info = host_info.clone();
            pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
                let injector = injector.clone();
                let ended = ended.clone();
                let closed = closed.clone();
                let host_info = host_info.clone();
                Box::pin(async move {
                    if dc.label() != "control" {
                        return;
                    }
                    serve_control_channel(dc, injector, ended, closed, host_info);
                })
            }));
        }

        let answer = pc.create_answer(None).await.context("create answer")?;
        pc.set_local_description(answer.clone())
            .await
            .context("set local description")?;
        outbound
            .send(answer_envelope(&answer.sdp))
            .context("queue SDP answer for signaling")?;

        for t in pc.get_transceivers().await {
            info!(
                "answer transceiver kind={} mid={:?} direction={:?} current={:?}",
                t.kind(),
                t.mid(),
                t.direction(),
                t.current_direction()
            );
        }
        tracing::debug!("local answer SDP:\n{}", answer.sdp);

        let host = Arc::new(Self {
            pc,
            closed: closed.clone(),
            capture_stop: Mutex::new(None),
            tasks: Mutex::new(Vec::new()),
        });

        // Defer capture + encode until DTLS is established (see `connected`
        // above). Capture is Windows-only; on the dev machine `start()`
        // returns a clear error and the session ends gracefully.
        {
            let host_for_task = Arc::clone(&host);
            let closed = closed.clone();
            let ended = ended.clone();
            let deferred = tokio::spawn(async move {
                connected.notified().await;
                if closed.load(Ordering::SeqCst) {
                    return;
                }
                let cap = match capture::start() {
                    Ok(cap) => cap,
                    Err(error) => {
                        error!("start screen/audio capture: {error:#}");
                        if !closed.swap(true, Ordering::SeqCst) {
                            ended.notify_one();
                        }
                        return;
                    }
                };
                info!(
                    "capturing {}x{} desktop (deferred until DTLS up)",
                    cap.width, cap.height
                );
                *host_for_task.capture_stop.lock().await = Some(cap.stop);
                host_for_task
                    .spawn_keyframe_listener(video_sender, Arc::clone(&keyframe_request))
                    .await;
                host_for_task
                    .spawn_video_pipeline(cap.video_rx, video_track, keyframe_request)
                    .await;
                host_for_task
                    .spawn_audio_pipeline(cap.audio_rx, audio_track)
                    .await;
            });
            host.tasks.lock().await.push(deferred);
        }
        Ok(host)
    }

    pub async fn add_remote_ice(&self, payload: &Map<String, Value>) {
        let Some(candidate) = payload.get("candidate").and_then(Value::as_str) else {
            return;
        };
        let init = RTCIceCandidateInit {
            candidate: candidate.to_owned(),
            sdp_mid: payload
                .get("sdpMid")
                .and_then(Value::as_str)
                .map(str::to_owned),
            sdp_mline_index: payload
                .get("sdpMLineIndex")
                .and_then(Value::as_str)
                .and_then(|s| s.parse::<u16>().ok()),
            username_fragment: None,
        };
        if let Err(error) = self.pc.add_ice_candidate(init).await {
            warn!("failed to add remote ICE candidate: {error}");
        }
    }

    pub async fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        // Dropping the stop handle halts the capture threads, which
        // closes the encoder channels and unwinds the pump tasks.
        self.capture_stop.lock().await.take();
        for task in self.tasks.lock().await.drain(..) {
            task.abort();
        }
        if let Err(error) = self.pc.close().await {
            warn!("error closing peer connection: {error}");
        }
    }

    async fn spawn_video_pipeline(
        &self,
        frames: LatestFrameReceiver,
        track: Arc<TrackLocalStaticSample>,
        keyframe_request: Arc<AtomicBool>,
    ) {
        // Bounded encoder→writer queue: prevents encoded H.264 frames
        // from piling up under network back-pressure. `blocking_send`
        // in the encoder thread stalls naturally when the writer is
        // saturated, which keeps glass-to-glass latency bounded instead
        // of growing without limit.
        let (enc_tx, mut enc_rx) = channel::<EncodedFrame>(2);

        // Encoder thread: OpenH264 is not `Send`, so build it here and
        // keep it on this thread for the session's lifetime.
        std::thread::Builder::new()
            .name("video-encoder".to_string())
            .spawn(move || {
                let mut encoder = match VideoEncoder::new(VIDEO_BITRATE_BPS, TARGET_FPS) {
                    Ok(encoder) => encoder,
                    Err(error) => {
                        error!("video encoder init failed: {error:#}");
                        return;
                    }
                };
                let mut raw = 0u64;
                let mut encoded = 0u64;
                // The most recent captured frame, re-encoded as an IDR when a
                // receiver asks for a keyframe but the screen is static (dirty-
                // region capture delivers nothing). Without this, a client that
                // joins or resizes mid-session stays black until the next pixel
                // changes.
                let mut last_frame: Option<capture::ScreenFrame> = None;
                loop {
                    let want_keyframe: bool;
                    let frame: &capture::ScreenFrame = match frames
                        .recv_timeout(Duration::from_millis(250))
                    {
                        capture::FrameRecv::Frame(fresh) => {
                            raw += 1;
                            if raw == 1 {
                                info!("video: first raw frame {}x{}", fresh.width, fresh.height);
                            }
                            last_frame = Some(fresh);
                            want_keyframe = keyframe_request.swap(false, Ordering::SeqCst);
                            last_frame.as_ref().unwrap()
                        }
                        capture::FrameRecv::Timeout => {
                            // Static screen: only spend bandwidth when a
                            // receiver is actually waiting for a keyframe.
                            if !take_keyframe_replay_request(
                                &keyframe_request,
                                last_frame.is_some(),
                            ) {
                                continue;
                            }
                            want_keyframe = true;
                            last_frame
                                .as_ref()
                                .expect("replay request requires a cached frame")
                        }
                        capture::FrameRecv::Closed => break,
                    };

                    if want_keyframe {
                        encoder.force_intra_frame();
                        info!("video: forcing IDR (receiver PLI/FIR)");
                    }
                    let captured_at = Instant::now();
                    match encoder.encode_bgra(&frame.data, frame.width, frame.height) {
                        Ok(annex_b) if !annex_b.is_empty() => {
                            encoded += 1;
                            if encoded % 120 == 1 {
                                info!(
                                    "video: encoded {encoded}/{raw} frames ({} B)",
                                    annex_b.len()
                                );
                            }
                            if enc_tx
                                .blocking_send(EncodedFrame {
                                    data: annex_b,
                                    captured_at,
                                })
                                .is_err()
                            {
                                break;
                            }
                        }
                        Ok(_) => {}
                        Err(error) => warn!("video encode failed: {error:#}"),
                    }
                }
            })
            .expect("spawn video encoder thread");

        let default_frame_duration = Duration::from_secs_f32(1.0 / TARGET_FPS);
        let writer = tokio::spawn(async move {
            let mut written = 0u64;
            let mut last_sent_at: Option<Instant> = None;
            while let Some(frame) = enc_rx.recv().await {
                // Sample `duration` advances the RTP timestamp, which
                // drives the receiver's jitter buffer. Using a constant
                // 1/TARGET_FPS even when frames actually arrive slower
                // makes the receiver clock drift behind wall time and
                // over-buffer. Use the real interval since the last
                // pushed sample instead, clamped to a sane range.
                let duration = match last_sent_at {
                    Some(prev) => frame
                        .captured_at
                        .saturating_duration_since(prev)
                        .clamp(Duration::from_millis(1), Duration::from_secs(1)),
                    None => default_frame_duration,
                };
                last_sent_at = Some(frame.captured_at);
                match track
                    .write_sample(&Sample {
                        data: Bytes::from(frame.data),
                        duration,
                        ..Default::default()
                    })
                    .await
                {
                    Ok(()) => {
                        written += 1;
                        if written % 120 == 1 {
                            info!("video: write_sample ok x{written}");
                        }
                    }
                    Err(error) => {
                        warn!("video write_sample failed: {error}");
                        break;
                    }
                }
            }
        });
        self.tasks.lock().await.push(writer);
    }

    async fn spawn_audio_pipeline(
        &self,
        samples: StdReceiver<Vec<f32>>,
        track: Arc<TrackLocalStaticSample>,
    ) {
        let (enc_tx, mut enc_rx) = unbounded_channel::<Vec<u8>>();

        std::thread::Builder::new()
            .name("audio-encoder".to_string())
            .spawn(move || {
                let mut encoder = match AudioEncoder::new() {
                    Ok(encoder) => encoder,
                    Err(error) => {
                        warn!("audio encoder init failed: {error:#}");
                        return;
                    }
                };
                let mut pending: Vec<f32> = Vec::with_capacity(OPUS_FRAME_INTERLEAVED * 4);
                let mut chunks = 0u64;
                let mut encoded = 0u64;
                while let Ok(chunk) = samples.recv() {
                    chunks += 1;
                    if chunks == 1 {
                        info!("audio: first loopback chunk ({} samples)", chunk.len());
                    }
                    pending.extend_from_slice(&chunk);
                    while pending.len() >= OPUS_FRAME_INTERLEAVED {
                        let frame: Vec<f32> = pending.drain(..OPUS_FRAME_INTERLEAVED).collect();
                        match encoder.encode_frame(&frame) {
                            Ok(packet) => {
                                encoded += 1;
                                if encoded % 250 == 1 {
                                    info!("audio: encoded {encoded} opus frames");
                                }
                                if enc_tx.send(packet).is_err() {
                                    return;
                                }
                            }
                            Err(error) => warn!("opus encode failed: {error:#}"),
                        }
                    }
                }
            })
            .expect("spawn audio encoder thread");

        let writer = tokio::spawn(async move {
            let mut written = 0u64;
            while let Some(packet) = enc_rx.recv().await {
                match track
                    .write_sample(&Sample {
                        data: Bytes::from(packet),
                        duration: Duration::from_millis(20),
                        ..Default::default()
                    })
                    .await
                {
                    Ok(()) => {
                        written += 1;
                        if written % 250 == 1 {
                            info!("audio: write_sample ok x{written}");
                        }
                    }
                    Err(error) => {
                        warn!("audio write_sample failed: {error}");
                        break;
                    }
                }
            }
        });
        self.tasks.lock().await.push(writer);
    }

    /// Drains RTCP from the video sender and flips `flag` whenever the
    /// receiver asks for a keyframe (PLI or FIR). The encoder thread
    /// consumes the flag before its next encode. Without this the iOS
    /// decoder is stuck on the first P-frame if it joined the session
    /// after the initial IDR was already sent.
    async fn spawn_keyframe_listener(&self, sender: Arc<RTCRtpSender>, flag: Arc<AtomicBool>) {
        let task = tokio::spawn(async move {
            loop {
                let pkts = match sender.read_rtcp().await {
                    Ok((pkts, _)) => pkts,
                    Err(_) => return, // sender closed
                };
                for pkt in pkts {
                    let any = pkt.as_any();
                    if any.is::<PictureLossIndication>() || any.is::<FullIntraRequest>() {
                        if !flag.swap(true, Ordering::SeqCst) {
                            info!("video: receiver requested keyframe (PLI/FIR)");
                        }
                        break;
                    }
                }
            }
        });
        self.tasks.lock().await.push(task);
    }
}

/// Adds a `sendonly` transceiver carrying `track`. Must be called
/// before `set_remote_description`: webrtc-rs then matches the client's
/// `recvonly` audio/video m-line to this local transceiver by kind +
/// direction (`satisfy_type_and_direction`). `add_transceiver_from_track`
/// builds a fully-initialized sender (with RTP encodings), so the track
/// actually sends — unlike `RTCRtpSender::replace_track`, which requires
/// pre-existing encodings and rejects an initial bind.
async fn add_send_transceiver(
    pc: &RTCPeerConnection,
    label: &str,
    track: Arc<TrackLocalStaticSample>,
) -> Result<Arc<RTCRtpSender>> {
    let track_dyn: Arc<dyn TrackLocal + Send + Sync> = track;
    let transceiver = pc
        .add_transceiver_from_track(
            track_dyn,
            Some(RTCRtpTransceiverInit {
                direction: RTCRtpTransceiverDirection::Sendonly,
                send_encodings: vec![],
            }),
        )
        .await?;
    info!(
        "added sendonly {label} transceiver kind={} direction={:?}",
        transceiver.kind(),
        transceiver.direction()
    );
    Ok(transceiver.sender().await)
}

/// Wires up the host side of the `control` data channel.
fn serve_control_channel(
    dc: Arc<RTCDataChannel>,
    injector: InputInjector,
    ended: Arc<Notify>,
    closed: Arc<AtomicBool>,
    host_info: HostInfo,
) {
    let seq = Arc::new(AtomicU32::new(0));
    let hello_authenticated = Arc::new(AtomicBool::new(false));
    let dc_for_msg = Arc::clone(&dc);
    dc.on_message(Box::new(move |msg: DataChannelMessage| {
        let injector = injector.clone();
        let ended = ended.clone();
        let closed = closed.clone();
        let host_info = host_info.clone();
        let seq = seq.clone();
        let hello_authenticated = hello_authenticated.clone();
        let dc = Arc::clone(&dc_for_msg);
        Box::pin(async move {
            let Some(message) = ClientMessage::decode(&msg.data) else {
                return; // unknown `t`: spec says ignore, don't disconnect
            };
            match message {
                ClientMessage::Hello { proto } => {
                    if proto != PROTOCOL_VERSION {
                        hello_authenticated.store(false, Ordering::SeqCst);
                        send_dc(&dc, protocol::encode_bye(next(&seq), now_us(), "protocol")).await;
                        if !closed.swap(true, Ordering::SeqCst) {
                            ended.notify_one();
                        }
                        return;
                    }
                    // Authenticate before the first await so a subsequent
                    // ordered control packet can never race ahead of this
                    // state transition.
                    hello_authenticated.store(true, Ordering::SeqCst);
                    send_dc(
                        &dc,
                        protocol::encode_hello_ack(
                            next(&seq),
                            now_us(),
                            &host_info,
                            true,
                            1,
                            TARGET_FPS as i64,
                        ),
                    )
                    .await;
                    let (width, height) = crate::capture::display_info().unwrap_or((0, 0));
                    send_dc(
                        &dc,
                        protocol::encode_display(
                            next(&seq),
                            now_us(),
                            DisplayInfo {
                                width: width as i32,
                                height: height as i32,
                                scale: 1.0,
                            },
                        ),
                    )
                    .await;
                }
                ClientMessage::Bye { .. } => {
                    hello_authenticated.store(false, Ordering::SeqCst);
                    if !closed.swap(true, Ordering::SeqCst) {
                        ended.notify_one();
                    }
                }
                message @ (ClientMessage::Pointer { .. }
                | ClientMessage::Scroll { .. }
                | ClientMessage::Key { .. }
                | ClientMessage::Text(_)) => {
                    if accepts_direct_input(&message, hello_authenticated.load(Ordering::SeqCst))
                        && !closed.load(Ordering::SeqCst)
                    {
                        injector.apply(message);
                    } else {
                        warn!("dropping remote input received before authenticated hello");
                    }
                }
                ClientMessage::Qos { .. } => {
                    if !hello_authenticated.load(Ordering::SeqCst) || closed.load(Ordering::SeqCst)
                    {
                        warn!("dropping video quality request received before authenticated hello");
                    }
                    // The current Windows encoder uses a fixed production
                    // policy. Authenticated QoS remains an explicit no-op
                    // until dynamic encoder reconfiguration is supported.
                }
            }
        })
    }));
}

/// Pointer and keyboard packets are privileged only after the peer has
/// completed the protocol hello. A WebRTC data channel opening is not, by
/// itself, authorization to control the PC.
fn accepts_direct_input(message: &ClientMessage, hello_authenticated: bool) -> bool {
    hello_authenticated
        && matches!(
            message,
            ClientMessage::Pointer { .. }
                | ClientMessage::Scroll { .. }
                | ClientMessage::Key { .. }
                | ClientMessage::Text(_)
        )
}

/// Consume a pending PLI/FIR only when a cached frame can be re-encoded. If
/// capture has not produced its first frame yet, leave the request set so that
/// fresh frame is forced to IDR instead of silently losing the receiver's
/// recovery request.
fn take_keyframe_replay_request(request: &AtomicBool, has_cached_frame: bool) -> bool {
    has_cached_frame && request.swap(false, Ordering::SeqCst)
}

async fn send_dc(dc: &Arc<RTCDataChannel>, bytes: Vec<u8>) {
    if let Err(error) = dc.send(&Bytes::from(bytes)).await {
        warn!("control channel send failed: {error}");
    }
}

fn next(seq: &AtomicU32) -> u32 {
    seq.fetch_add(1, Ordering::SeqCst).wrapping_add(1)
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn answer_envelope(sdp: &str) -> SignalingEnvelope {
    let mut payload = Map::new();
    payload.insert("sdp".to_string(), Value::String(sdp.to_string()));
    payload.insert("sdpType".to_string(), Value::String("answer".to_string()));
    SignalingEnvelope {
        role: Role::Host,
        kind: Kind::Answer,
        payload,
        ts: now_s(),
    }
}

fn ice_envelope(init: &RTCIceCandidateInit) -> SignalingEnvelope {
    let mut payload = Map::new();
    payload.insert(
        "candidate".to_string(),
        Value::String(init.candidate.clone()),
    );
    payload.insert(
        "sdpMid".to_string(),
        Value::String(init.sdp_mid.clone().unwrap_or_default()),
    );
    payload.insert(
        "sdpMLineIndex".to_string(),
        Value::String(init.sdp_mline_index.unwrap_or(0).to_string()),
    );
    SignalingEnvelope {
        role: Role::Host,
        kind: Kind::Ice,
        payload,
        ts: now_s(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ScrollPhase;

    #[test]
    fn direct_input_requires_an_authenticated_hello_for_every_variant() {
        let messages = [
            ClientMessage::Pointer {
                x: 1,
                y: 2,
                buttons: 1,
            },
            ClientMessage::Scroll {
                dx: 3,
                dy: 4,
                phase: ScrollPhase::Changed,
            },
            ClientMessage::Key {
                usage: 5,
                down: true,
                modifiers: 0,
            },
            ClientMessage::Text("safe input".to_string()),
        ];

        for message in &messages {
            assert!(!accepts_direct_input(message, false));
            assert!(accepts_direct_input(message, true));
        }
    }

    #[test]
    fn protocol_messages_are_never_treated_as_direct_input() {
        let messages = [
            ClientMessage::Hello {
                proto: PROTOCOL_VERSION,
            },
            ClientMessage::Qos {
                target_fps: 60,
                max_bitrate_kbps: 8_000,
                prefer: "auto".to_string(),
            },
            ClientMessage::Bye {
                reason: "user".to_string(),
            },
        ];

        for message in &messages {
            assert!(!accepts_direct_input(message, false));
            assert!(!accepts_direct_input(message, true));
        }
    }

    #[test]
    fn keyframe_request_waits_for_the_first_captured_frame() {
        let request = AtomicBool::new(true);

        assert!(!take_keyframe_replay_request(&request, false));
        assert!(request.load(Ordering::SeqCst));
        assert!(request.swap(false, Ordering::SeqCst));
    }

    #[test]
    fn keyframe_request_replays_once_when_a_cached_frame_exists() {
        let request = AtomicBool::new(true);

        assert!(take_keyframe_replay_request(&request, true));
        assert!(!request.load(Ordering::SeqCst));
        assert!(!take_keyframe_replay_request(&request, true));
    }
}

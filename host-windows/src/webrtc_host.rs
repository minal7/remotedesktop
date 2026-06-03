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
use std::net::IpAddr;
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
use webrtc::ice::network_type::NetworkType;
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
/// Hard ceiling on the wall-clock gap between IDR frames. OpenH264's
/// frame-count GOP (`IntraFramePeriod`) turns into a wall-clock interval
/// of `GOP / actual_fps`, so when the encoder runs below `TARGET_FPS`
/// (1440p on a busy machine often only manages 7–10 fps), the "every 2s"
/// nominal GOP stretches to 15+ s of P-frame-only output. A late-joining
/// or briefly-deafened iOS decoder then sits black until the next
/// PLI/FIR loops around. Forcing an IDR every `IDR_WALL_INTERVAL` of
/// real time bounds that recovery window regardless of encoder
/// throughput.
const IDR_WALL_INTERVAL: Duration = Duration::from_secs(2);

/// How long the connection may sit in ICE `disconnected` before we tear
/// the session down and return to advertising. webrtc-rs only emits
/// `failed` after `ICE_FAILED_TIMEOUT` of further silence, so without
/// this grace timer an abruptly-gone iOS client (app killed, Wi-Fi
/// dropped — no `bye` sent) would keep the host "Connected" for ~30s.
const DISCONNECT_GRACE: Duration = Duration::from_secs(3);
/// Shorter-than-default ICE liveness windows so a dead peer is noticed
/// quickly. Defaults are 5s/25s/2s; media flows continuously while a
/// session is healthy, so these only bite once the peer truly stops.
const ICE_DISCONNECTED_TIMEOUT: Duration = Duration::from_secs(3);
const ICE_FAILED_TIMEOUT: Duration = Duration::from_secs(7);
const ICE_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(1);

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
        let mut setting_engine = SettingEngine::default();
        setting_engine.set_ice_timeouts(
            Some(ICE_DISCONNECTED_TIMEOUT),
            Some(ICE_FAILED_TIMEOUT),
            Some(ICE_KEEPALIVE_INTERVAL),
        );
        // Drop ICE candidates that can never carry a real session. A
        // multi-homed Windows host (e.g. Wi-Fi + a 100.64/10 CGNAT path,
        // plus dead 169.254 link-local addresses) otherwise gathers
        // candidates on every interface; ICE then nominates a pair that
        // passes the one-shot STUN check but can't sustain the DTLS
        // handshake, so the peer times out. Keep ordinary LAN, public,
        // and global IPv6 addresses; discard link-local, CGNAT/shared,
        // and unique-local addresses.
        setting_engine.set_ip_filter(Box::new(usable_ice_ip));
        // IPv4 + IPv6 ICE. IPv6 is back on now that the real cause of the
        // Windows IPv6 failure is fixed: webrtc-util mis-parsed Windows
        // IPv6 interface addresses, byte-swapping every 16-bit group
        // (`fe80::b774:…` came back as `80fe::74b7:…`), so the host could
        // never bind an IPv6 socket and gathered no usable IPv6
        // candidate. The earlier symptom — ICE flips to `connected` over
        // an IPv6 pair but DTLS never completes and the iOS client times
        // out with "can't reach your computer" — came from that corruption.
        // The fix lives in the vendored webrtc-util (see the `[patch]` in
        // Cargo.toml); with correct addresses, a direct IPv6 path is the
        // fastest route when both ends have global IPv6. `usable_ice_ip`
        // still drops link-local / ULA / CGNAT so only routable addresses
        // are offered.
        setting_engine.set_network_types(vec![
            NetworkType::Udp4,
            NetworkType::Tcp4,
            NetworkType::Udp6,
            NetworkType::Tcp6,
        ]);
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

        // Log the nominated ICE pair so the path that actually carries
        // (or fails to carry) DTLS + media is visible in host.log. This
        // is the difference between "ICE says connected" and "the peer
        // connection reached Connected": if these diverge, the selected
        // pair passed STUN but couldn't complete DTLS.
        {
            let dtls_transport = pc.sctp().transport();
            let ice_transport = dtls_transport.ice_transport();
            ice_transport.on_selected_candidate_pair_change(Box::new(|pair| {
                info!(
                    "ICE selected pair: local={} remote={}",
                    pair.local.address, pair.remote.address
                );
                Box::pin(async {})
            }));
        }

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
                            if !candidate_usable_for_signaling(&init.candidate) {
                                info!("dropping local ICE candidate from an unusable interface");
                                return;
                            }
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
        {
            let ended = ended.clone();
            let closed = closed.clone();
            let connection_generation = connection_generation.clone();
            let keyframe_request = Arc::clone(&keyframe_request);
            pc.on_peer_connection_state_change(Box::new(move |state| {
                let ended = ended.clone();
                let closed = closed.clone();
                let connection_generation = connection_generation.clone();
                let keyframe_request = Arc::clone(&keyframe_request);
                Box::pin(async move {
                    info!("peer connection state → {state:?}");
                    match state {
                        RTCPeerConnectionState::Connected => {
                            // Supersede any in-flight disconnect grace timer.
                            connection_generation.fetch_add(1, Ordering::SeqCst);
                            // Force an IDR as soon as SRTP is actually up.
                            // The encoder has been running since `start()`
                            // returned — well before ICE/DTLS finished —
                            // so its initial IDR was packetized into a
                            // socket that had nowhere to send. Without
                            // this nudge, a slow client sees only
                            // P-frames until the next periodic IDR
                            // (~2s of encoder time later) or until iOS
                            // gets around to sending a PLI, which is
                            // what made the screen stay black while
                            // mouse input still worked.
                            if !keyframe_request.swap(true, Ordering::SeqCst) {
                                info!("video: requesting IDR after peer became connected");
                            }
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

        // Capture is Windows-only; on the dev machine this returns a
        // clear error and the session ends gracefully.
        let cap = capture::start().context("start screen/audio capture")?;
        info!("capturing {}x{} desktop", cap.width, cap.height);

        let host = Arc::new(Self {
            pc,
            closed,
            capture_stop: Mutex::new(Some(cap.stop)),
            tasks: Mutex::new(Vec::new()),
        });

        host.spawn_keyframe_listener(video_sender, Arc::clone(&keyframe_request))
            .await;
        host.spawn_video_pipeline(cap.video_rx, video_track, keyframe_request)
            .await;
        host.spawn_audio_pipeline(cap.audio_rx, audio_track).await;
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
                // `last_idr_at = None` so the very first encoded frame
                // counts as the session's IDR (OpenH264 always emits one
                // up front) and the wall-clock timer starts from there.
                let mut last_idr_at: Option<Instant> = None;
                while let Some(frame) = frames.recv() {
                    raw += 1;
                    if raw == 1 {
                        info!("video: first raw frame {}x{}", frame.width, frame.height);
                    }
                    let pli_requested = keyframe_request.swap(false, Ordering::SeqCst);
                    let wall_clock_overdue = last_idr_at
                        .map(|t| t.elapsed() >= IDR_WALL_INTERVAL)
                        .unwrap_or(false);
                    if pli_requested || wall_clock_overdue {
                        encoder.force_intra_frame();
                        if pli_requested {
                            info!("video: forcing IDR (receiver PLI/FIR)");
                        } else {
                            info!("video: forcing IDR (wall-clock fallback)");
                        }
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
                            // Reset the wall-clock IDR timer whenever a
                            // frame actually lands. We can't tell from
                            // here whether OpenH264 emitted an IDR or a
                            // P-frame, but on the first frame and after
                            // a `force_intra_frame()` call it always
                            // emits an IDR, so the timer represents an
                            // upper bound on time-since-last-IDR.
                            if last_idr_at.is_none() || pli_requested || wall_clock_overdue {
                                last_idr_at = Some(captured_at);
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
    let dc_for_msg = Arc::clone(&dc);
    dc.on_message(Box::new(move |msg: DataChannelMessage| {
        let injector = injector.clone();
        let ended = ended.clone();
        let closed = closed.clone();
        let host_info = host_info.clone();
        let seq = seq.clone();
        let dc = Arc::clone(&dc_for_msg);
        Box::pin(async move {
            let Some(message) = ClientMessage::decode(&msg.data) else {
                return; // unknown `t`: spec says ignore, don't disconnect
            };
            match message {
                ClientMessage::Hello { proto } => {
                    if proto != PROTOCOL_VERSION {
                        send_dc(&dc, protocol::encode_bye(next(&seq), now_us(), "protocol")).await;
                        if !closed.swap(true, Ordering::SeqCst) {
                            ended.notify_one();
                        }
                        return;
                    }
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
                    if !closed.swap(true, Ordering::SeqCst) {
                        ended.notify_one();
                    }
                }
                other => injector.apply(other),
            }
        })
    }));
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

/// ICE candidate IP filter: `true` keeps the address. Discards classes
/// that can't form a usable peer path — IPv4 link-local (169.254/16) and
/// CGNAT/shared (100.64/10), and IPv6 link-local (fe80::/10) and
/// unique-local (fc00::/7) — while keeping ordinary private LAN, public,
/// and global IPv6 addresses.
fn usable_ice_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            let is_cgnat = o[0] == 100 && (o[1] & 0xC0) == 0x40; // 100.64.0.0/10
            !v4.is_link_local() && !is_cgnat && !v4.is_loopback() && !v4.is_unspecified()
        }
        IpAddr::V6(v6) => {
            let seg0 = v6.segments()[0];
            let is_link_local = (seg0 & 0xFFC0) == 0xFE80; // fe80::/10
            let is_unique_local = (seg0 & 0xFE00) == 0xFC00; // fc00::/7
            !is_link_local && !is_unique_local && !v6.is_loopback() && !v6.is_unspecified()
        }
    }
}

fn candidate_usable_for_signaling(candidate: &str) -> bool {
    let fields = candidate.split_whitespace().collect::<Vec<_>>();
    let Some(address) = fields.get(4).and_then(|value| value.parse::<IpAddr>().ok()) else {
        return true;
    };
    let candidate_type = field_after(&fields, "typ");
    if candidate_type == Some("relay") {
        return true;
    }
    if !usable_ice_ip(address) {
        return false;
    }

    if matches!(candidate_type, Some("srflx" | "prflx")) {
        if let Some(related_address) =
            field_after(&fields, "raddr").and_then(|value| value.parse::<IpAddr>().ok())
        {
            return usable_ice_ip(related_address);
        }
    }

    true
}

fn field_after<'a>(fields: &'a [&str], key: &str) -> Option<&'a str> {
    fields
        .windows(2)
        .find_map(|pair| (pair[0] == key).then_some(pair[1]))
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
    use super::{candidate_usable_for_signaling, usable_ice_ip};
    use std::net::IpAddr;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn keeps_lan_public_and_global_ipv6() {
        assert!(usable_ice_ip(ip("192.168.4.24"))); // LAN
        assert!(usable_ice_ip(ip("10.0.0.5"))); // LAN
        assert!(usable_ice_ip(ip("172.16.3.9"))); // LAN
        assert!(usable_ice_ip(ip("23.93.209.157"))); // public srflx
        assert!(usable_ice_ip(ip("2600:1010:b216:468d::1"))); // global IPv6
    }

    #[test]
    fn drops_link_local_cgnat_and_unique_local() {
        assert!(!usable_ice_ip(ip("169.254.100.182"))); // IPv4 link-local
        assert!(!usable_ice_ip(ip("100.80.197.84"))); // CGNAT 100.64/10
        assert!(!usable_ice_ip(ip("100.64.0.1"))); // CGNAT lower bound
        assert!(!usable_ice_ip(ip("100.127.255.255"))); // CGNAT upper bound
        assert!(usable_ice_ip(ip("100.128.0.1"))); // just outside CGNAT — kept
        assert!(!usable_ice_ip(ip("fe80::1"))); // IPv6 link-local
        assert!(!usable_ice_ip(ip("fd40:be80:c900::1"))); // IPv6 unique-local
    }

    #[test]
    fn drops_signaled_candidates_from_unusable_interfaces() {
        assert!(!candidate_usable_for_signaling(
            "candidate:1 1 udp 2122260223 100.89.100.91 51101 typ host"
        ));
        assert!(!candidate_usable_for_signaling(
            "candidate:2 1 udp 1686052607 174.239.179.186 3731 typ srflx raddr 100.89.100.91 rport 51101"
        ));
        assert!(!candidate_usable_for_signaling(
            "candidate:3 1 udp 2122260223 fd40:be80:c900::1 57031 typ host"
        ));
    }

    #[test]
    fn keeps_signaled_candidates_from_reachable_interfaces() {
        assert!(candidate_usable_for_signaling(
            "candidate:1 1 udp 2122260223 192.168.4.24 63374 typ host"
        ));
        assert!(candidate_usable_for_signaling(
            "candidate:2 1 udp 1686052607 23.93.209.157 64080 typ srflx raddr 192.168.4.24 rport 64080"
        ));
        assert!(candidate_usable_for_signaling(
            "candidate:3 1 udp 41885695 203.0.113.10 50000 typ relay raddr 100.89.100.91 rport 51101"
        ));
    }
}

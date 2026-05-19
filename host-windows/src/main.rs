use anyhow::{Context, Result};
use serde_json::{Map, Value};
use std::sync::Arc;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tokio::sync::Notify;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

mod auth;
mod capture;
mod cloudkit;
mod config;
mod credentials;
mod iceconfig;
mod identity;
mod input;
mod media;
mod protocol;
mod signaling;
mod webrtc_host;

use auth::AppleIdAuthenticator;
use cloudkit::CloudKitClient;
use config::AppConfig;
use credentials::CredentialStore;
use input::InputInjector;
use protocol::HostInfo;
use signaling::{
    new_pairing_code, HostSignalingClient, HostSignalingOptions, Kind, SignalingEnvelope,
};
use webrtc_host::WebRtcHost;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,remote_desktop_host=debug")),
        )
        .init();

    let config = AppConfig::from_env()?;
    info!(
        "CloudKit Apple ID callback URL must be configured as {}",
        config.auth_callback_url()
    );

    let credentials = CredentialStore::new();
    let cloudkit = CloudKitClient::new(config.cloudkit.clone(), credentials.clone());
    let authenticator = AppleIdAuthenticator::new(
        cloudkit.clone(),
        credentials.clone(),
        config.auth_callback_bind,
        config.auth_callback_path.clone(),
    );
    let user = authenticator.require_signed_in().await?;
    info!(
        "Apple ID CloudKit sign-in accepted for user record {}",
        user.user_record_name
    );

    let sender_id = identity::get_or_create_device_id(&credentials)?;
    let host_name = host_name();
    let stun_urls = iceconfig::stun_urls(&cloudkit).await;
    let injector = InputInjector::spawn()
        .context("couldn't start input injection (is this account allowed to send input?)")?;

    run_host(config, cloudkit, sender_id, host_name, stun_urls, injector).await
}

async fn run_host(
    config: AppConfig,
    cloudkit: CloudKitClient,
    sender_id: String,
    host_name: String,
    stun_urls: Vec<String>,
    injector: InputInjector,
) -> Result<()> {
    loop {
        let code = new_pairing_code();
        let mut signaling = HostSignalingClient::new(
            cloudkit.clone(),
            HostSignalingOptions {
                code,
                sender_id: sender_id.clone(),
                host_name: host_name.clone(),
                stale_record_seconds: config.stale_record_seconds,
            },
        );

        signaling.claim().await?;
        println!("Remote Desktop Host for Windows");
        println!("Signed in with Apple ID and advertising this computer.");
        println!("Pairing code: {}", signaling.code());
        info!("advertising Windows host code={}", signaling.code());

        let session = Session::new(stun_urls.clone(), host_name.clone(), injector.clone());
        let loop_exit = session.advertising_loop(&mut signaling, &config).await;
        session.shutdown_peer().await;

        if let Err(error) = signaling.cleanup().await {
            warn!("CloudKit cleanup failed: {error:#}");
        }

        match loop_exit? {
            LoopExit::Restart => continue,
            LoopExit::Shutdown => return Ok(()),
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum LoopExit {
    Restart,
    Shutdown,
}

/// One pairing attempt: drives signaling, owns the live peer session
/// and the channel the peer uses to push answer/ICE back out.
struct Session {
    stun_urls: Vec<String>,
    host_name: String,
    injector: InputInjector,
    ended: Arc<Notify>,
    outbound_tx: UnboundedSender<SignalingEnvelope>,
    outbound_rx: tokio::sync::Mutex<UnboundedReceiver<SignalingEnvelope>>,
    peer: tokio::sync::Mutex<Option<Arc<WebRtcHost>>>,
    buffered_remote_ice: tokio::sync::Mutex<Vec<Map<String, Value>>>,
}

impl Session {
    fn new(stun_urls: Vec<String>, host_name: String, injector: InputInjector) -> Self {
        let (outbound_tx, outbound_rx) = unbounded_channel();
        Self {
            stun_urls,
            host_name,
            injector,
            ended: Arc::new(Notify::new()),
            outbound_tx,
            outbound_rx: tokio::sync::Mutex::new(outbound_rx),
            peer: tokio::sync::Mutex::new(None),
            buffered_remote_ice: tokio::sync::Mutex::new(Vec::new()),
        }
    }

    async fn advertising_loop(
        &self,
        signaling: &mut HostSignalingClient,
        config: &AppConfig,
    ) -> Result<LoopExit> {
        let mut outbound_rx = self.outbound_rx.lock().await;
        loop {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    info!("shutdown requested");
                    return Ok(LoopExit::Shutdown);
                }
                _ = self.ended.notified() => {
                    info!("peer session ended — restarting listener");
                    return Ok(LoopExit::Restart);
                }
                Some(envelope) = outbound_rx.recv() => {
                    if let Err(error) = signaling.send(envelope).await {
                        error!("couldn't forward signaling envelope: {error:#}");
                    }
                }
                _ = tokio::time::sleep(config.poll_interval) => {
                    match signaling.poll().await {
                        Ok(envelopes) => {
                            for envelope in envelopes {
                                if self.handle_envelope(signaling, envelope).await? == Action::Restart {
                                    return Ok(LoopExit::Restart);
                                }
                            }
                        }
                        Err(error) => error!("CloudKit poll failed: {error:#}"),
                    }
                }
            }
        }
    }

    async fn handle_envelope(
        &self,
        signaling: &mut HostSignalingClient,
        envelope: SignalingEnvelope,
    ) -> Result<Action> {
        match envelope.kind {
            Kind::Offer => {
                let client = string_payload(&envelope.payload, "client").unwrap_or("client");
                match envelope.payload.get("sdp").and_then(Value::as_str) {
                    Some(sdp) => self.start_peer(client, sdp.to_string()).await,
                    None => {
                        info!("received preflight offer from {client}");
                        signaling
                            .send(SignalingEnvelope::host_answer(host_metadata(
                                &self.host_name,
                            )))
                            .await
                            .context("couldn't send preflight answer")?;
                        Ok(Action::Continue)
                    }
                }
            }
            Kind::Ice => {
                let peer = self.peer.lock().await;
                if let Some(peer) = peer.as_ref() {
                    peer.add_remote_ice(&envelope.payload).await;
                } else {
                    self.buffered_remote_ice.lock().await.push(envelope.payload);
                }
                Ok(Action::Continue)
            }
            Kind::Bye => {
                info!("client ended the pairing attempt");
                Ok(Action::Restart)
            }
            Kind::Answer => {
                warn!("host received unexpected answer envelope");
                Ok(Action::Continue)
            }
        }
    }

    async fn start_peer(&self, client: &str, sdp: String) -> Result<Action> {
        if self.peer.lock().await.is_some() {
            return Ok(Action::Continue);
        }
        info!("received WebRTC offer from {client}");
        match WebRtcHost::start(
            sdp,
            self.stun_urls.clone(),
            self.outbound_tx.clone(),
            self.ended.clone(),
            self.injector.clone(),
            host_info(&self.host_name),
        )
        .await
        {
            Ok(host) => {
                let buffered: Vec<_> =
                    self.buffered_remote_ice.lock().await.drain(..).collect();
                for payload in buffered {
                    host.add_remote_ice(&payload).await;
                }
                *self.peer.lock().await = Some(host);
                Ok(Action::Continue)
            }
            Err(error) => {
                error!("couldn't start WebRTC session: {error:#}");
                self.outbound_tx
                    .send(SignalingEnvelope::host_bye(&format!(
                        "The Windows host couldn't start the screen session: {error}"
                    )))
                    .ok();
                Ok(Action::Restart)
            }
        }
    }

    async fn shutdown_peer(&self) {
        if let Some(peer) = self.peer.lock().await.take() {
            peer.close().await;
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum Action {
    Continue,
    Restart,
}

fn host_info(host_name: &str) -> HostInfo {
    HostInfo {
        app: "RemoteDesktop-Windows".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        os: windows_version_label(),
        hostname: host_name.to_string(),
    }
}

fn host_metadata(host_name: &str) -> Map<String, Value> {
    Map::from_iter([
        ("host".to_string(), Value::String(host_name.to_string())),
        (
            "app".to_string(),
            Value::String("RemoteDesktop-Windows".to_string()),
        ),
        (
            "version".to_string(),
            Value::String(env!("CARGO_PKG_VERSION").to_string()),
        ),
        ("os".to_string(), Value::String(windows_version_label())),
        ("audio".to_string(), Value::String("true".to_string())),
        ("monitors".to_string(), Value::String("1".to_string())),
        ("displayWidth".to_string(), Value::String("0".to_string())),
        ("displayHeight".to_string(), Value::String("0".to_string())),
        (
            "displayScale".to_string(),
            Value::String("1.00".to_string()),
        ),
    ])
}

fn host_name() -> String {
    hostname::get()
        .ok()
        .and_then(|name| name.into_string().ok())
        .filter(|name| !name.trim().is_empty())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_else(|| "Windows PC".to_string())
}

fn windows_version_label() -> String {
    #[cfg(windows)]
    {
        std::env::var("OS").unwrap_or_else(|_| "Windows".to_string())
    }
    #[cfg(not(windows))]
    {
        "Windows".to_string()
    }
}

fn string_payload<'a>(payload: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(Value::as_str)
}

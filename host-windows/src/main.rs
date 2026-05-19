use anyhow::{Context, Result};
use serde_json::{Map, Value};
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

mod auth;
mod cloudkit;
mod config;
mod credentials;
mod identity;
mod signaling;

use auth::AppleIdAuthenticator;
use cloudkit::CloudKitClient;
use config::AppConfig;
use credentials::CredentialStore;
use signaling::{
    new_pairing_code, HostSignalingClient, HostSignalingOptions, Kind, SignalingEnvelope,
};

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
    run_host(config, cloudkit, sender_id, host_name).await
}

async fn run_host(
    config: AppConfig,
    cloudkit: CloudKitClient,
    sender_id: String,
    host_name: String,
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

        let loop_exit = advertising_loop(&mut signaling, &config).await;
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

async fn advertising_loop(
    signaling: &mut HostSignalingClient,
    config: &AppConfig,
) -> Result<LoopExit> {
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                info!("shutdown requested");
                return Ok(LoopExit::Shutdown);
            }
            poll_result = signaling.poll() => {
                match poll_result {
                    Ok(envelopes) => {
                        for envelope in envelopes {
                            if handle_envelope(signaling, envelope).await? == EnvelopeAction::Restart {
                                return Ok(LoopExit::Restart);
                            }
                        }
                    }
                    Err(error) => {
                        error!("CloudKit poll failed: {error:#}");
                    }
                }
            }
        }

        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                info!("shutdown requested");
                return Ok(LoopExit::Shutdown);
            }
            _ = tokio::time::sleep(config.poll_interval) => {}
        }
    }
}

async fn handle_envelope(
    signaling: &mut HostSignalingClient,
    envelope: SignalingEnvelope,
) -> Result<EnvelopeAction> {
    match envelope.kind {
        Kind::Offer => {
            let client = string_payload(&envelope.payload, "client").unwrap_or("client");
            if envelope.payload.get("sdp").is_some() {
                warn!(
                    "received WebRTC SDP offer from {client}; full Windows WebRTC is not wired yet"
                );
                signaling
                    .send(SignalingEnvelope::host_bye(
                        "Windows host sign-in and pairing are ready; WebRTC screen capture is not implemented yet.",
                    ))
                    .await
                    .context("couldn't notify client that Windows WebRTC is not ready")?;
                return Ok(EnvelopeAction::Continue);
            }

            info!("received preflight offer from {client}");
            signaling
                .send(SignalingEnvelope::host_answer(host_metadata()))
                .await
                .context("couldn't send preflight answer")?;
            Ok(EnvelopeAction::Continue)
        }
        Kind::Ice => {
            info!("buffering/ignoring ICE until Windows WebRTC host peer is implemented");
            Ok(EnvelopeAction::Continue)
        }
        Kind::Bye => {
            info!("client ended the pairing attempt");
            Ok(EnvelopeAction::Restart)
        }
        Kind::Answer => {
            warn!("host received unexpected answer envelope");
            Ok(EnvelopeAction::Continue)
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum EnvelopeAction {
    Continue,
    Restart,
}

fn host_metadata() -> Map<String, Value> {
    Map::from_iter([
        ("host".to_string(), Value::String(host_name())),
        (
            "app".to_string(),
            Value::String("RemoteDesktop-Windows".to_string()),
        ),
        (
            "version".to_string(),
            Value::String(env!("CARGO_PKG_VERSION").to_string()),
        ),
        ("os".to_string(), Value::String(windows_version_label())),
        ("audio".to_string(), Value::String("false".to_string())),
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

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use std::sync::Arc;
use std::sync::RwLock;
use std::thread;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tokio::sync::Notify;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

mod app_state;
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
mod ui;
mod webrtc_host;

use app_state::{AppState, Command, CommandSender, HostStatus, SharedState};
use auth::AppleIdAuthenticator;
use cloudkit::CloudKitClient;
use config::AppConfig;
use credentials::CredentialStore;
use input::InputInjector;
use protocol::HostInfo;
use signaling::{
    advertisement_refresh_interval, new_pairing_code, HostSignalingClient, HostSignalingOptions,
    Kind, SignalingEnvelope,
};
use webrtc_host::WebRtcHost;

fn main() -> Result<()> {
    let _ = dotenvy::dotenv();
    init_logging();

    let state: SharedState = Arc::new(RwLock::new(AppState::default()));
    let (cmd_tx, cmd_rx) = unbounded_channel::<Command>();
    let commands = CommandSender(cmd_tx);

    let state_for_runtime = state.clone();
    let runtime_thread = thread::Builder::new()
        .name("host-runtime".to_string())
        .spawn(move || run_runtime(state_for_runtime, cmd_rx))
        .context("failed to start runtime thread")?;

    let icon = ui::make_icon();
    let tray_menu = tray_icon::menu::Menu::new();
    let show_item = tray_icon::menu::MenuItem::new("Show Remote Desktop Host", true, None);
    let quit_item = tray_icon::menu::MenuItem::new("Quit", true, None);
    let _ = tray_menu.append_items(&[
        &show_item,
        &tray_icon::menu::PredefinedMenuItem::separator(),
        &quit_item,
    ]);

    let tray_icon = tray_icon::Icon::from_rgba(icon.rgba.clone(), icon.width, icon.height)
        .expect("failed to create tray icon");

    let _tray = tray_icon::TrayIconBuilder::new()
        .with_menu(Box::new(tray_menu))
        .with_tooltip("Remote Desktop Host")
        .with_icon(tray_icon)
        .with_menu_on_left_click(false)
        .build()
        .expect("failed to build tray icon");

    let native_options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("Remote Desktop Host")
            .with_inner_size([380.0, 460.0])
            .with_min_inner_size([320.0, 380.0])
            .with_icon(Arc::new(icon)),
        ..Default::default()
    };

    let ui_state = state.clone();
    let ui_commands = commands.clone();
    let show_item_id = show_item.id().clone();
    let quit_item_id = quit_item.id().clone();
    let result = eframe::run_native(
        "Remote Desktop Host",
        native_options,
        Box::new(move |cc| {
            cc.egui_ctx.set_visuals(eframe::egui::Visuals::dark());
            Ok(Box::new(ui::HostApp::new(
                ui_state,
                ui_commands,
                cc.egui_ctx.clone(),
                show_item_id,
                quit_item_id,
            )))
        }),
    );

    // UI is closed. The HostApp's on_exit handler already enqueued
    // Command::Quit so the runtime should be tearing itself down.
    let _ = runtime_thread.join();

    if let Err(error) = result {
        eprintln!("eframe failed: {error}");
        std::process::exit(1);
    }
    Ok(())
}

fn run_runtime(state: SharedState, cmd_rx: UnboundedReceiver<Command>) {
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            error!("failed to start tokio runtime: {error:#}");
            app_state::set_status(
                &state,
                HostStatus::Error(format!("Couldn't start runtime: {error}")),
            );
            return;
        }
    };
    runtime.block_on(controller(state, cmd_rx));
}

fn init_logging() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,remote_desktop_host=debug"));

    let log_path = log_path();
    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        Ok(file) => {
            let writer = std::sync::Mutex::new(file);
            tracing_subscriber::fmt()
                .with_env_filter(env_filter)
                .with_ansi(false)
                .with_writer(writer)
                .init();
        }
        Err(_) => {
            tracing_subscriber::fmt().with_env_filter(env_filter).init();
        }
    }
}

fn log_path() -> std::path::PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("RemoteDesktopHost").join("host.log")
}

#[derive(Clone)]
struct ControllerDeps {
    config: AppConfig,
    cloudkit: CloudKitClient,
    sender_id: String,
    host_name: String,
    stun_urls: Vec<String>,
    injector: InputInjector,
}

async fn controller(state: SharedState, mut cmd_rx: UnboundedReceiver<Command>) {
    let deps = match setup(&state).await {
        Ok(deps) => deps,
        Err(error) => {
            error!("setup failed: {error:#}");
            app_state::set_status(
                &state,
                HostStatus::Error(format!("Couldn't start: {error}")),
            );
            // Still drain commands so UI buttons aren't deadlocked.
            while let Some(cmd) = cmd_rx.recv().await {
                if matches!(cmd, Command::Quit) {
                    return;
                }
            }
            return;
        }
    };

    app_state::set_host_name(&state, deps.host_name.clone());

    let (session_end_tx, mut session_end_rx) = unbounded_channel::<Result<()>>();

    // Match the historical Windows host behavior: as soon as setup
    // completes, start advertising automatically. The user can still
    // press Stop in the UI to go idle, then Start to resume.
    app_state::set_status(&state, HostStatus::Starting);
    let auto_start = Arc::new(Notify::new());
    spawn_session(
        &deps,
        state.clone(),
        auto_start.clone(),
        session_end_tx.clone(),
    );
    let mut current_shutdown: Option<Arc<Notify>> = Some(auto_start);
    info!("controller ready, auto-started advertising");

    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { return; };
                match cmd {
                    Command::Start => {
                        if current_shutdown.is_some() {
                            continue;
                        }
                        app_state::set_status(&state, HostStatus::Starting);
                        let shutdown = Arc::new(Notify::new());
                        spawn_session(
                            &deps,
                            state.clone(),
                            shutdown.clone(),
                            session_end_tx.clone(),
                        );
                        current_shutdown = Some(shutdown);
                    }
                    Command::Stop => {
                        if let Some(shutdown) = current_shutdown.take() {
                            shutdown.notify_one();
                            let result = session_end_rx.recv().await;
                            log_session_result(result);
                        }
                        app_state::set_status(&state, HostStatus::Idle);
                    }
                    Command::Quit => {
                        if let Some(shutdown) = current_shutdown.take() {
                            shutdown.notify_one();
                            let _ = session_end_rx.recv().await;
                        }
                        return;
                    }
                }
            }
            Some(result) = session_end_rx.recv() => {
                current_shutdown = None;
                match result {
                    Ok(()) => {
                        app_state::set_status(&state, HostStatus::Idle);
                    }
                    Err(error) => {
                        app_state::set_status(
                            &state,
                            HostStatus::Error(format!("{error}")),
                        );
                    }
                }
            }
        }
    }
}

fn log_session_result(result: Option<Result<()>>) {
    match result {
        Some(Ok(())) => info!("session stopped cleanly"),
        Some(Err(error)) => warn!("session ended with error: {error:#}"),
        None => warn!("session result channel closed unexpectedly"),
    }
}

fn spawn_session(
    deps: &ControllerDeps,
    state: SharedState,
    shutdown: Arc<Notify>,
    session_end_tx: UnboundedSender<Result<()>>,
) {
    let deps = deps.clone();
    tokio::spawn(async move {
        let result = run_host(state.clone(), shutdown, deps).await;
        let _ = session_end_tx.send(result);
    });
}

async fn setup(state: &SharedState) -> Result<ControllerDeps> {
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

    app_state::set_status(state, HostStatus::SigningIn);
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

    Ok(ControllerDeps {
        config,
        cloudkit,
        sender_id,
        host_name,
        stun_urls,
        injector,
    })
}

async fn run_host(state: SharedState, shutdown: Arc<Notify>, deps: ControllerDeps) -> Result<()> {
    let ControllerDeps {
        config,
        cloudkit,
        sender_id,
        host_name,
        stun_urls,
        injector,
    } = deps;

    let mdns = mdns_sd::ServiceDaemon::new().ok();

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
        app_state::set_status(
            &state,
            HostStatus::Advertising {
                code: signaling.code().to_string(),
            },
        );
        info!("advertising Windows host code={}", signaling.code());

        let instance_name = format!("{} [{}]", host_name, signaling.code());
        let service_type = "_remotedesktop._tcp.local.";
        let fullname = format!("{}.{}", instance_name, service_type);
        if let Some(mdns) = &mdns {
            let host_name_local = format!("{}.local.", host_name.replace(" ", "-"));
            let properties: [(&str, &str); 0] = [];
            match mdns_sd::ServiceInfo::new(
                service_type,
                &instance_name,
                &host_name_local,
                "0.0.0.0",
                9,
                &properties[..],
            ) {
                Ok(info) => {
                    let info = info.enable_addr_auto();
                    if let Err(error) = mdns.register(info) {
                        warn!("mDNS registration failed: {error:#}");
                    }
                }
                Err(error) => {
                    warn!("mDNS ServiceInfo creation failed: {error:#}");
                }
            }
        }

        let session = Session::new(
            stun_urls.clone(),
            host_name.clone(),
            injector.clone(),
            state.clone(),
            shutdown.clone(),
        );
        let loop_exit = session.advertising_loop(&mut signaling, &config).await;
        session.shutdown_peer().await;

        if let Some(mdns) = &mdns {
            let _ = mdns.unregister(&fullname);
        }

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
    shutdown: Arc<Notify>,
    state: SharedState,
    outbound_tx: UnboundedSender<SignalingEnvelope>,
    outbound_rx: tokio::sync::Mutex<UnboundedReceiver<SignalingEnvelope>>,
    peer: tokio::sync::Mutex<Option<Arc<WebRtcHost>>>,
    buffered_remote_ice: tokio::sync::Mutex<Vec<Map<String, Value>>>,
}

impl Session {
    fn new(
        stun_urls: Vec<String>,
        host_name: String,
        injector: InputInjector,
        state: SharedState,
        shutdown: Arc<Notify>,
    ) -> Self {
        let (outbound_tx, outbound_rx) = unbounded_channel();
        Self {
            stun_urls,
            host_name,
            injector,
            ended: Arc::new(Notify::new()),
            shutdown,
            state,
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
        let advertisement_refresh_interval =
            advertisement_refresh_interval(config.stale_record_seconds);
        let advertisement_refresh_retry_interval =
            Duration::from_secs(30).min(advertisement_refresh_interval);
        let mut next_advertisement_refresh = Instant::now() + advertisement_refresh_interval;
        loop {
            tokio::select! {
                _ = self.shutdown.notified() => {
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
                    if Instant::now() >= next_advertisement_refresh
                        && self.peer.lock().await.is_none()
                    {
                        match signaling.refresh_advertisement().await {
                            Ok(()) => {
                                info!("refreshed Windows host advertisement");
                                next_advertisement_refresh =
                                    Instant::now() + advertisement_refresh_interval;
                            }
                            Err(error) => {
                                error!("CloudKit advertisement refresh failed: {error:#}");
                                next_advertisement_refresh =
                                    Instant::now() + advertisement_refresh_retry_interval;
                            }
                        }
                    }

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
                    Some(sdp) => {
                        let action = self.start_peer(client, sdp.to_string()).await?;
                        if self.peer.lock().await.is_some() {
                            if let Err(error) = signaling.stop_advertising().await {
                                error!(
                                    "couldn't remove host advertisement after pairing: {error:#}"
                                );
                            }
                        }
                        Ok(action)
                    }
                    None => {
                        info!("received preflight offer from {client}");
                        signaling
                            .send(SignalingEnvelope::host_answer(host_metadata(
                                &self.host_name,
                            )))
                            .await
                            .context("couldn't send preflight answer")?;
                        if let Err(error) = signaling.stop_advertising().await {
                            error!("couldn't remove host advertisement after preflight pairing: {error:#}");
                        }
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
                let buffered: Vec<_> = self.buffered_remote_ice.lock().await.drain(..).collect();
                for payload in buffered {
                    host.add_remote_ice(&payload).await;
                }
                *self.peer.lock().await = Some(host);
                app_state::set_status(
                    &self.state,
                    HostStatus::Paired {
                        client: client.to_string(),
                    },
                );
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
    let (width, height) = crate::capture::display_info().unwrap_or((0, 0));
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
        ("displayWidth".to_string(), Value::String(width.to_string())),
        (
            "displayHeight".to_string(),
            Value::String(height.to_string()),
        ),
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

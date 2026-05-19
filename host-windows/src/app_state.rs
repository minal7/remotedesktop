//! Shared state between the host controller (background tokio runtime)
//! and the egui UI (main thread). The controller writes the current
//! `HostStatus`; the UI reads it on every frame and sends `Command`s
//! back through an `UnboundedSender` to ask the controller to start
//! or stop advertising.

use std::sync::{Arc, RwLock};
use tokio::sync::mpsc::UnboundedSender;

#[derive(Clone, Debug, Default)]
pub enum HostStatus {
    #[default]
    Initializing,
    SigningIn,
    Idle,
    Starting,
    Advertising {
        code: String,
    },
    Paired {
        client: String,
    },
    Error(String),
}

impl HostStatus {
    pub fn short_label(&self) -> &'static str {
        match self {
            Self::Initializing => "Starting…",
            Self::SigningIn => "Signing in",
            Self::Idle => "Ready",
            Self::Starting => "Starting…",
            Self::Advertising { .. } => "Waiting for pairing",
            Self::Paired { .. } => "Connected",
            Self::Error(_) => "Error",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct AppState {
    pub status: HostStatus,
    pub host_name: String,
}

pub type SharedState = Arc<RwLock<AppState>>;

#[derive(Clone, Debug)]
pub enum Command {
    Start,
    Stop,
    Quit,
}

pub fn set_status(state: &SharedState, status: HostStatus) {
    if let Ok(mut guard) = state.write() {
        guard.status = status;
    }
}

pub fn set_host_name(state: &SharedState, host_name: String) {
    if let Ok(mut guard) = state.write() {
        guard.host_name = host_name;
    }
}

#[derive(Clone)]
pub struct CommandSender(pub UnboundedSender<Command>);

impl CommandSender {
    pub fn send(&self, command: Command) {
        let _ = self.0.send(command);
    }
}

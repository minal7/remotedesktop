//! CloudKit signaling client (Web Services REST).
//!
//! Planned surface:
//! - `HostAdvertisement` record writes on pairing-code show.
//! - `WebRTCSignal` record poll at 2 s cadence; `targetID == self` filter.
//! - Web Auth Token bootstrapped via a one-shot `wry` webview and stored
//!   in the Windows Credential Manager.
//!
//! Until any of that exists, this file is a placeholder to wire the
//! module path into the binary.

use tracing::debug;

pub fn hello() {
    debug!("signaling module: stub — nothing wired yet.");
}

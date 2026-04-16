//! Windows host entrypoint. Currently a stub — it exists to pin the
//! crate layout and prove the toolchain compiles. The real agent grows
//! here one subsystem at a time (CloudKit → WebRTC → capture → input),
//! mirroring `host-mac/RemoteDesktopHost` one module for one module.

use anyhow::Result;
use tracing::info;
use tracing_subscriber::EnvFilter;

mod signaling;

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,remote_desktop_host=debug")),
        )
        .init();

    info!("Remote Desktop host (Windows) — stub build. See PROGRESS.md.");
    signaling::hello();
    Ok(())
}

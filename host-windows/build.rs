//! Build script. Two jobs:
//!
//! 1. Tell Cargo to rebuild when the baked-in CloudKit settings change so
//!    release builds pick up a freshly supplied token (via `option_env!`
//!    in `config.rs`) without needing a clean.
//! 2. On Windows, embed the application icon and version metadata into the
//!    `.exe` so it shows a real icon in Explorer / the taskbar and carries
//!    proper file-properties (used by the installer and the Store later).

fn main() {
    println!("cargo:rerun-if-env-changed=REMOTE_DESKTOP_CLOUDKIT_API_TOKEN");
    println!("cargo:rerun-if-env-changed=REMOTE_DESKTOP_CLOUDKIT_ENV");
    println!("cargo:rerun-if-env-changed=REMOTE_DESKTOP_CLOUDKIT_CONTAINER");

    #[cfg(windows)]
    embed_windows_resources();
}

#[cfg(windows)]
fn embed_windows_resources() {
    println!("cargo:rerun-if-changed=assets/icon.ico");

    let mut res = winresource::WindowsResource::new();
    res.set_icon("assets/icon.ico");
    res.set("ProductName", "Remote Desktop Host");
    res.set("FileDescription", "Remote Desktop Host");
    res.set("CompanyName", "Threadmark");
    res.set(
        "LegalCopyright",
        "Copyright (c) Threadmark. All rights reserved.",
    );
    res.set("OriginalFilename", "remote-desktop-host.exe");

    // The resource compiler (rc.exe from the Windows SDK, bundled with the
    // MSVC build tools) is required to embed these. Degrade to a warning
    // rather than failing the build on dev machines that lack it; release
    // pipelines run on a runner that has the SDK installed.
    if let Err(error) = res.compile() {
        println!("cargo:warning=could not embed Windows icon/version resources: {error}");
    }
}

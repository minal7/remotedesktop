//! User-facing preferences that persist across launches, stored as JSON
//! in `%LOCALAPPDATA%\RemoteDesktopHost\settings.json`. Kept separate
//! from `AppConfig` (which is environment/deployment configuration the
//! user never edits through the UI).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    /// Whether the host registers itself to launch when the user signs
    /// in to Windows. Defaults to `true` so a freshly-installed host is
    /// always reachable without the user remembering to open it.
    #[serde(default = "default_true")]
    pub launch_at_login: bool,
}

fn default_true() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            launch_at_login: default_true(),
        }
    }
}

/// Result of loading settings, distinguishing a genuine first run (no
/// file yet) from a returning user. On first run the caller applies the
/// `launch_at_login` default and persists it.
pub struct LoadedSettings {
    pub settings: Settings,
    pub first_run: bool,
}

pub fn settings_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("RemoteDesktopHost").join("settings.json")
}

pub fn load() -> LoadedSettings {
    let path = settings_path();
    match std::fs::read_to_string(&path) {
        Ok(contents) => {
            let settings = serde_json::from_str(&contents).unwrap_or_default();
            LoadedSettings {
                settings,
                first_run: false,
            }
        }
        Err(_) => LoadedSettings {
            settings: Settings::default(),
            first_run: true,
        },
    }
}

pub fn save(settings: &Settings) -> Result<()> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("create settings directory")?;
    }
    let json = serde_json::to_string_pretty(settings).context("serialize settings")?;
    std::fs::write(&path, json).context("write settings file")?;
    Ok(())
}

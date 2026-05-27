use anyhow::{anyhow, Context, Result};
use std::{env, net::SocketAddr, str::FromStr, time::Duration};

pub const DEFAULT_CONTAINER_IDENTIFIER: &str = "iCloud.com.threadmark.remotedesktop";
pub const DEFAULT_AUTH_CALLBACK_BIND: &str = "127.0.0.1:48172";
pub const DEFAULT_AUTH_CALLBACK_PATH: &str = "/icloud-auth-callback";

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub cloudkit: CloudKitConfig,
    pub auth_callback_bind: SocketAddr,
    pub auth_callback_path: String,
    pub poll_interval: Duration,
    pub stale_record_seconds: u64,
}

#[derive(Clone, Debug)]
pub struct CloudKitConfig {
    pub container_identifier: String,
    pub environment: CloudKitEnvironment,
    pub api_token: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudKitEnvironment {
    Development,
    Production,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let api_token = resolve(
            env::var("REMOTE_DESKTOP_CLOUDKIT_API_TOKEN").ok(),
            option_env!("REMOTE_DESKTOP_CLOUDKIT_API_TOKEN"),
        )
        .context(
            "REMOTE_DESKTOP_CLOUDKIT_API_TOKEN is required. Create a CloudKit API token for the container and set it before launching the Windows host (or bake it in at build time).",
        )?;

        let environment = resolve(
            env::var("REMOTE_DESKTOP_CLOUDKIT_ENV").ok(),
            option_env!("REMOTE_DESKTOP_CLOUDKIT_ENV"),
        )
        .unwrap_or_else(|| "development".to_string())
        .parse()
        .context("REMOTE_DESKTOP_CLOUDKIT_ENV must be either development or production")?;

        let auth_callback_bind = env::var("REMOTE_DESKTOP_AUTH_CALLBACK_BIND")
            .unwrap_or_else(|_| DEFAULT_AUTH_CALLBACK_BIND.to_string())
            .parse()
            .with_context(|| {
                format!(
                    "REMOTE_DESKTOP_AUTH_CALLBACK_BIND must be a socket address like {DEFAULT_AUTH_CALLBACK_BIND}"
                )
            })?;

        let auth_callback_path = normalize_path(
            env::var("REMOTE_DESKTOP_AUTH_CALLBACK_PATH")
                .unwrap_or_else(|_| DEFAULT_AUTH_CALLBACK_PATH.to_string()),
        );

        Ok(Self {
            cloudkit: CloudKitConfig {
                container_identifier: resolve(
                    env::var("REMOTE_DESKTOP_CLOUDKIT_CONTAINER").ok(),
                    option_env!("REMOTE_DESKTOP_CLOUDKIT_CONTAINER"),
                )
                .unwrap_or_else(|| DEFAULT_CONTAINER_IDENTIFIER.to_string()),
                environment,
                api_token,
            },
            auth_callback_bind,
            auth_callback_path,
            poll_interval: Duration::from_secs(read_u64_env("REMOTE_DESKTOP_POLL_SECONDS", 2)?),
            stale_record_seconds: read_u64_env("REMOTE_DESKTOP_STALE_SECONDS", 300)?,
        })
    }

    pub fn auth_callback_url(&self) -> String {
        format!(
            "http://{}{}",
            self.auth_callback_bind, self.auth_callback_path
        )
    }
}

impl CloudKitEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Production => "production",
        }
    }
}

impl FromStr for CloudKitEnvironment {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "development" | "dev" => Ok(Self::Development),
            "production" | "prod" => Ok(Self::Production),
            other => Err(anyhow!("unsupported CloudKit environment: {other}")),
        }
    }
}

/// Resolve a setting, preferring a value set in the process environment
/// (handy for local dev / `.env` overrides) and falling back to a value
/// baked into the binary at compile time via `option_env!`. Distributed
/// release builds embed the CloudKit token this way so the executable
/// runs with no per-machine setup; blank values are treated as unset.
fn resolve(runtime: Option<String>, compiled: Option<&'static str>) -> Option<String> {
    runtime
        .or_else(|| compiled.map(str::to_string))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn read_u64_env(key: &str, default: u64) -> Result<u64> {
    match env::var(key) {
        Ok(value) => value
            .parse()
            .with_context(|| format!("{key} must be an unsigned integer")),
        Err(_) => Ok(default),
    }
}

fn normalize_path(path: String) -> String {
    if path.starts_with('/') {
        path
    } else {
        format!("/{path}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloudkit_environment_accepts_short_names() {
        assert_eq!(
            "dev".parse::<CloudKitEnvironment>().unwrap(),
            CloudKitEnvironment::Development
        );
        assert_eq!(
            "prod".parse::<CloudKitEnvironment>().unwrap(),
            CloudKitEnvironment::Production
        );
    }

    #[test]
    fn normalize_path_adds_leading_slash() {
        assert_eq!(normalize_path("callback".to_string()), "/callback");
        assert_eq!(normalize_path("/callback".to_string()), "/callback");
    }

    #[test]
    fn resolve_prefers_runtime_over_compiled() {
        assert_eq!(
            resolve(Some("runtime".to_string()), Some("compiled")),
            Some("runtime".to_string())
        );
    }

    #[test]
    fn resolve_falls_back_to_compiled() {
        assert_eq!(resolve(None, Some("compiled")), Some("compiled".to_string()));
    }

    #[test]
    fn resolve_treats_blank_as_unset() {
        assert_eq!(resolve(Some("   ".to_string()), Some("compiled")), None);
        assert_eq!(resolve(None, Some("")), None);
        assert_eq!(resolve(None, None), None);
    }
}

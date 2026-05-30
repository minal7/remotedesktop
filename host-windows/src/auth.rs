use crate::{
    cloudkit::{CloudKitClient, CloudKitError, CurrentUser},
    credentials::CredentialStore,
};
use anyhow::{anyhow, Context, Result};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::{timeout, Instant},
};
use tokio_rustls::{
    rustls::{
        crypto::aws_lc_rs,
        pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
        ServerConfig,
    },
    TlsAcceptor,
};
use tracing::{info, warn};
use url::Url;

const AUTH_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Clone, Debug)]
pub struct AppleIdAuthenticator {
    cloudkit: CloudKitClient,
    credentials: CredentialStore,
    callback_bind: SocketAddr,
    callback_path: String,
}

impl AppleIdAuthenticator {
    pub fn new(
        cloudkit: CloudKitClient,
        credentials: CredentialStore,
        callback_bind: SocketAddr,
        callback_path: impl Into<String>,
    ) -> Self {
        Self {
            cloudkit,
            credentials,
            callback_bind,
            callback_path: callback_path.into(),
        }
    }

    pub async fn require_signed_in(&self) -> Result<CurrentUser> {
        match self.cloudkit.current_user().await {
            Ok(user) => return Ok(user),
            Err(CloudKitError::MissingWebAuthToken)
            | Err(CloudKitError::AuthenticationRequired { .. })
            | Err(CloudKitError::AuthenticationFailed(_)) => {
                info!("Apple ID sign-in is required before advertising this host");
            }
            Err(error) => return Err(error).context("failed to check Apple ID sign-in"),
        }

        self.prompt_for_apple_id().await?;
        self.cloudkit
            .current_user()
            .await
            .context("Apple ID sign-in finished, but CloudKit did not accept the new token")
    }

    async fn prompt_for_apple_id(&self) -> Result<()> {
        let listener = TcpListener::bind(self.callback_bind)
            .await
            .with_context(|| {
                format!(
                    "couldn't listen for Apple ID callback on https://{}{}",
                    self.callback_bind, self.callback_path
                )
            })?;
        let acceptor =
            build_tls_acceptor().context("couldn't set up TLS for the Apple ID callback")?;

        let redirect_url = self
            .cloudkit
            .authentication_redirect_url()
            .await
            .context("couldn't get Apple ID sign-in URL from CloudKit")?;

        info!("opening Apple ID sign-in prompt");
        println!(
            "Apple ID sign-in required. A browser window is opening so this Windows host can use your private CloudKit signaling records."
        );
        println!(
            "CloudKit API token Sign-In Callback must be configured as: https://{}{}",
            self.callback_bind, self.callback_path
        );
        println!(
            "Your browser will warn about the local self-signed certificate; choose to proceed to finish signing in."
        );
        webbrowser::open(&redirect_url)
            .with_context(|| format!("couldn't open Apple ID sign-in URL: {redirect_url}"))?;

        let token = wait_for_callback(listener, acceptor, &self.callback_path, AUTH_TIMEOUT).await?;
        self.cloudkit_credentials_set_web_auth_token(&token)?;
        Ok(())
    }

    fn cloudkit_credentials_set_web_auth_token(&self, token: &str) -> Result<()> {
        // Route through a tiny authenticated no-op would consume the token.
        // Store it first; the caller immediately validates it with users/caller,
        // which also catches invalid or stale callback tokens.
        self.credentials
            .set_web_auth_token(token)
            .context("couldn't save Apple ID CloudKit token")
    }
}

/// Builds a TLS acceptor backed by a fresh self-signed certificate for
/// `127.0.0.1`/`localhost`. CloudKit demands an `https` Sign-In Callback in
/// production; the cert is untrusted, so the browser shows a one-time warning
/// the user clicks through to deliver the `ckWebAuthToken` to the host.
fn build_tls_acceptor() -> Result<TlsAcceptor> {
    let certified = rcgen::generate_simple_self_signed(vec![
        "127.0.0.1".to_string(),
        "localhost".to_string(),
    ])
    .context("couldn't generate a self-signed certificate for the callback listener")?;
    let cert_der = certified.cert.der().clone();
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(certified.key_pair.serialize_der()));

    let config = ServerConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .context("couldn't select TLS protocol versions for the callback listener")?
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key_der)
        .context("couldn't load the self-signed certificate for the callback listener")?;

    Ok(TlsAcceptor::from(Arc::new(config)))
}

async fn wait_for_callback(
    listener: TcpListener,
    acceptor: TlsAcceptor,
    callback_path: &str,
    auth_timeout: Duration,
) -> Result<String> {
    let deadline = Instant::now() + auth_timeout;

    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| anyhow!("timed out waiting for Apple ID sign-in"))?;
        let (tcp_stream, _) = timeout(remaining, listener.accept())
            .await
            .map_err(|_| anyhow!("timed out waiting for Apple ID sign-in"))??;
        let mut stream = match acceptor.accept(tcp_stream).await {
            Ok(stream) => stream,
            Err(error) => {
                warn!("TLS handshake on the Apple ID callback failed: {error}");
                continue;
            }
        };

        let mut buffer = vec![0_u8; 8192];
        let bytes_read = stream.read(&mut buffer).await?;
        let request = String::from_utf8_lossy(&buffer[..bytes_read]);
        let request_line = request.lines().next().unwrap_or_default();

        if let Some(token) = parse_web_auth_token_request_line(request_line, callback_path) {
            let response = html_response(
                "200 OK",
                "Remote Desktop Host is signed in. You can close this window.",
            );
            stream.write_all(response.as_bytes()).await?;
            stream.flush().await?;
            return Ok(token);
        }

        warn!("received Apple ID callback without ckWebAuthToken");
        let response = html_response(
            "400 Bad Request",
            "Remote Desktop Host did not receive a CloudKit auth token. Return to the sign-in page and try again.",
        );
        stream.write_all(response.as_bytes()).await?;
        stream.flush().await?;
    }
}

fn parse_web_auth_token_request_line(request_line: &str, callback_path: &str) -> Option<String> {
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?;
    let target = parts.next()?;
    if method != "GET" {
        return None;
    }

    let url = if target.starts_with("http://") || target.starts_with("https://") {
        Url::parse(target).ok()?
    } else {
        Url::parse(&format!("http://localhost{target}")).ok()?
    };

    if url.path() != callback_path {
        return None;
    }

    url.query_pairs()
        .find(|(key, _)| key == "ckWebAuthToken")
        .map(|(_, value)| value.into_owned().replace(' ', "+"))
        .filter(|value| !value.trim().is_empty())
}

fn html_response(status: &str, message: &str) -> String {
    let body = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>Remote Desktop Host</title><body style=\"font-family:system-ui,sans-serif;margin:2rem\"><h1>{message}</h1></body>"
    );
    format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_parser_extracts_ck_web_auth_token() {
        let token = parse_web_auth_token_request_line(
            "GET /icloud-auth-callback?ckWebAuthToken=a%2Bb%2Fc%3D HTTP/1.1",
            "/icloud-auth-callback",
        );
        assert_eq!(token.as_deref(), Some("a+b/c="));
    }

    #[test]
    fn callback_parser_rejects_wrong_path() {
        let token = parse_web_auth_token_request_line(
            "GET /other?ckWebAuthToken=token HTTP/1.1",
            "/icloud-auth-callback",
        );
        assert_eq!(token, None);
    }
}

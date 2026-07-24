use keyring::Entry;
use std::sync::Arc;
use thiserror::Error;

const SERVICE: &str = "com.threadmark.remotedesktop.host-windows";
const DEVICE_ID_ACCOUNT: &str = "device-id";
const WEB_AUTH_ACCOUNT_PREFIX: &str = "cloudkit-web-auth:v1";
const MAXIMUM_CONTAINER_IDENTIFIER_BYTES: usize = 255;

#[derive(Clone, Debug)]
pub struct CredentialStore {
    device_id_entry: Arc<Entry>,
    web_auth_entry: Arc<Entry>,
}

#[derive(Debug, Error)]
pub enum CredentialError {
    #[error("credential store error: {0}")]
    Keyring(#[from] keyring::Error),
    #[error("CloudKit credential scope is invalid")]
    InvalidCloudKitScope,
    #[error("refusing to store an empty CloudKit web-auth token")]
    EmptyWebAuthToken,
}

impl CredentialStore {
    pub fn new(container_identifier: &str, environment: &str) -> Result<Self, CredentialError> {
        let web_auth_account = web_auth_account(container_identifier, environment)?;
        Ok(Self {
            device_id_entry: Arc::new(Entry::new(SERVICE, DEVICE_ID_ACCOUNT)?),
            web_auth_entry: Arc::new(Entry::new(SERVICE, &web_auth_account)?),
        })
    }

    pub fn web_auth_token(&self) -> Result<Option<String>, CredentialError> {
        get_secret(&self.web_auth_entry)
    }

    pub fn set_web_auth_token(&self, token: &str) -> Result<(), CredentialError> {
        if token.trim().is_empty() {
            return Err(CredentialError::EmptyWebAuthToken);
        }
        self.web_auth_entry.set_password(token)?;
        Ok(())
    }

    pub fn clear_web_auth_token(&self) -> Result<(), CredentialError> {
        match self.web_auth_entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn device_id(&self) -> Result<Option<String>, CredentialError> {
        get_secret(&self.device_id_entry)
    }

    pub fn set_device_id(&self, device_id: &str) -> Result<(), CredentialError> {
        self.device_id_entry.set_password(device_id)?;
        Ok(())
    }

    #[cfg(test)]
    fn from_entries(
        container_identifier: &str,
        environment: &str,
        device_id_entry: Entry,
        web_auth_entry: Entry,
    ) -> Result<Self, CredentialError> {
        web_auth_account(container_identifier, environment)?;
        Ok(Self {
            device_id_entry: Arc::new(device_id_entry),
            web_auth_entry: Arc::new(web_auth_entry),
        })
    }
}

fn get_secret(entry: &Entry) -> Result<Option<String>, CredentialError> {
    match entry.get_password() {
        Ok(secret) if secret.trim().is_empty() => Ok(None),
        Ok(secret) => Ok(Some(secret)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn web_auth_account(
    container_identifier: &str,
    environment: &str,
) -> Result<String, CredentialError> {
    let valid_container = !container_identifier.is_empty()
        && container_identifier.len() <= MAXIMUM_CONTAINER_IDENTIFIER_BYTES
        && container_identifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'));
    let valid_environment = matches!(environment, "development" | "production");
    if !valid_container || !valid_environment {
        return Err(CredentialError::InvalidCloudKitScope);
    }
    Ok(format!(
        "{WEB_AUTH_ACCOUNT_PREFIX}:{environment}:{container_identifier}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring::{mock::MockCredential, Error};

    fn mock_store(container: &str, environment: &str) -> CredentialStore {
        CredentialStore::from_entries(
            container,
            environment,
            Entry::new_with_credential(Box::<MockCredential>::default()),
            Entry::new_with_credential(Box::<MockCredential>::default()),
        )
        .unwrap()
    }

    fn web_auth_mock(store: &CredentialStore) -> &MockCredential {
        store
            .web_auth_entry
            .get_credential()
            .downcast_ref::<MockCredential>()
            .unwrap()
    }

    #[test]
    fn web_auth_namespace_is_bound_to_container_and_environment() {
        let development =
            web_auth_account("iCloud.com.threadmark.remotedesktop", "development").unwrap();
        let production =
            web_auth_account("iCloud.com.threadmark.remotedesktop", "production").unwrap();
        let other_container = web_auth_account("iCloud.com.example.other", "production").unwrap();

        assert_ne!(development, production);
        assert_ne!(production, other_container);
        assert_eq!(
            production,
            "cloudkit-web-auth:v1:production:iCloud.com.threadmark.remotedesktop"
        );
    }

    #[test]
    fn invalid_or_ambiguous_web_auth_scopes_fail_closed() {
        for (container, environment) in [
            ("", "production"),
            ("iCloud.com.example\nother", "production"),
            ("iCloud.com.example:other", "production"),
            ("iCloud.com.example", "Production"),
            ("iCloud.com.example", "unknown"),
        ] {
            assert!(matches!(
                web_auth_account(container, environment),
                Err(CredentialError::InvalidCloudKitScope)
            ));
        }
    }

    #[test]
    fn web_auth_token_round_trips_only_through_keyring_entry() {
        let store = mock_store("iCloud.com.threadmark.remotedesktop", "production");
        let large_token = "a".repeat(2000);

        assert_eq!(store.web_auth_token().unwrap(), None);
        store.set_web_auth_token(&large_token).unwrap();
        assert_eq!(store.web_auth_token().unwrap(), Some(large_token));
        store.clear_web_auth_token().unwrap();
        assert_eq!(store.web_auth_token().unwrap(), None);
        store.clear_web_auth_token().unwrap();
    }

    #[test]
    fn keyring_write_and_clear_errors_are_propagated() {
        let store = mock_store("iCloud.com.threadmark.remotedesktop", "production");
        web_auth_mock(&store).set_error(Error::Invalid(
            "injected write failure".to_string(),
            "test".to_string(),
        ));
        assert!(matches!(
            store.set_web_auth_token("secret"),
            Err(CredentialError::Keyring(Error::Invalid(_, _)))
        ));

        store.set_web_auth_token("secret").unwrap();
        web_auth_mock(&store).set_error(Error::Invalid(
            "injected clear failure".to_string(),
            "test".to_string(),
        ));
        assert!(matches!(
            store.clear_web_auth_token(),
            Err(CredentialError::Keyring(Error::Invalid(_, _)))
        ));
        assert_eq!(
            store.web_auth_token().unwrap().as_deref(),
            Some("secret"),
            "a failed clear must not be treated as a successful credential removal"
        );
    }

    #[test]
    fn empty_web_auth_token_is_rejected_without_mutating_keyring() {
        let store = mock_store("iCloud.com.threadmark.remotedesktop", "production");
        assert!(matches!(
            store.set_web_auth_token(" \t"),
            Err(CredentialError::EmptyWebAuthToken)
        ));
        assert_eq!(store.web_auth_token().unwrap(), None);
    }
}

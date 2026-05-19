use keyring::Entry;
use thiserror::Error;

const SERVICE: &str = "com.threadmark.remotedesktop.host-windows";
const WEB_AUTH_TOKEN_ACCOUNT: &str = "cloudkit-web-auth-token";
const DEVICE_ID_ACCOUNT: &str = "device-id";

#[derive(Clone, Debug, Default)]
pub struct CredentialStore;

#[derive(Debug, Error)]
pub enum CredentialError {
    #[error("credential store error: {0}")]
    Keyring(#[from] keyring::Error),
}

impl CredentialStore {
    pub fn new() -> Self {
        Self
    }

    pub fn web_auth_token(&self) -> Result<Option<String>, CredentialError> {
        self.get_secret(WEB_AUTH_TOKEN_ACCOUNT)
    }

    pub fn set_web_auth_token(&self, token: &str) -> Result<(), CredentialError> {
        self.set_secret(WEB_AUTH_TOKEN_ACCOUNT, token)
    }

    pub fn clear_web_auth_token(&self) -> Result<(), CredentialError> {
        self.delete_secret(WEB_AUTH_TOKEN_ACCOUNT)
    }

    pub fn device_id(&self) -> Result<Option<String>, CredentialError> {
        self.get_secret(DEVICE_ID_ACCOUNT)
    }

    pub fn set_device_id(&self, device_id: &str) -> Result<(), CredentialError> {
        self.set_secret(DEVICE_ID_ACCOUNT, device_id)
    }

    fn get_secret(&self, account: &str) -> Result<Option<String>, CredentialError> {
        let entry = Entry::new(SERVICE, account)?;
        match entry.get_password() {
            Ok(secret) if secret.trim().is_empty() => Ok(None),
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn set_secret(&self, account: &str, secret: &str) -> Result<(), CredentialError> {
        let entry = Entry::new(SERVICE, account)?;
        entry.set_password(secret)?;
        Ok(())
    }

    fn delete_secret(&self, account: &str) -> Result<(), CredentialError> {
        let entry = Entry::new(SERVICE, account)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

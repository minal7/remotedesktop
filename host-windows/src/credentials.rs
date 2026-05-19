use keyring::Entry;
use thiserror::Error;

const SERVICE: &str = "com.threadmark.remotedesktop.host-windows";
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

    fn token_path() -> std::path::PathBuf {
        let mut path = std::env::var("LOCALAPPDATA")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("C:\\ProgramData"));
        path.push("remote-desktop-host");
        let _ = std::fs::create_dir_all(&path);
        path.push("cloudkit_token.txt");
        path
    }

    pub fn web_auth_token(&self) -> Result<Option<String>, CredentialError> {
        match std::fs::read_to_string(Self::token_path()) {
            Ok(token) if token.trim().is_empty() => Ok(None),
            Ok(token) => Ok(Some(token)),
            Err(_) => Ok(None),
        }
    }

    pub fn set_web_auth_token(&self, token: &str) -> Result<(), CredentialError> {
        let _ = std::fs::write(Self::token_path(), token);
        Ok(())
    }

    pub fn clear_web_auth_token(&self) -> Result<(), CredentialError> {
        let _ = std::fs::remove_file(Self::token_path());
        Ok(())
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_large_secret() {
        let store = CredentialStore::new();
        let large_token = "a".repeat(2000);
        store.set_web_auth_token(&large_token).unwrap();
        let retrieved = store.web_auth_token().unwrap().unwrap();
        assert_eq!(large_token, retrieved);
        store.clear_web_auth_token().unwrap();
    }
}

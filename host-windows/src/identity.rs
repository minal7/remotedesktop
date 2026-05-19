use crate::credentials::CredentialStore;
use anyhow::{Context, Result};
use uuid::Uuid;

pub fn get_or_create_device_id(credentials: &CredentialStore) -> Result<String> {
    if let Some(device_id) = credentials
        .device_id()
        .context("couldn't read Windows host device identity")?
    {
        return Ok(device_id);
    }

    let device_id = Uuid::new_v4().to_string();
    credentials
        .set_device_id(&device_id)
        .context("couldn't persist Windows host device identity")?;
    Ok(device_id)
}

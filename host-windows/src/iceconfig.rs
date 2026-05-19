//! Fetches the single well-known `ICEConfig` record from the CloudKit
//! **Public DB** (`recordName == "default"`) for the STUN URL list —
//! the Rust mirror of `protocol/Swift/ICEConfigFetcher.swift`. Editing
//! that one record in the Dashboard rotates STUN for every client with
//! no release. STUN-only by design; any error falls back to a short
//! baked-in list so first-run / offline still works.

use crate::cloudkit::CloudKitClient;
use serde_json::{json, Value};
use tracing::info;

/// Same fallback list as the Apple clients (`ICEConfig.fallback`).
pub fn fallback_stun_urls() -> Vec<String> {
    vec![
        "stun:stun.l.google.com:19302".to_string(),
        "stun:stun.cloudflare.com:3478".to_string(),
    ]
}

pub async fn stun_urls(cloudkit: &CloudKitClient) -> Vec<String> {
    match fetch(cloudkit).await {
        Some(urls) if !urls.is_empty() => {
            info!("using {} STUN URL(s) from CloudKit ICEConfig", urls.len());
            urls
        }
        _ => {
            info!("ICEConfig unavailable; using baked-in STUN list");
            fallback_stun_urls()
        }
    }
}

async fn fetch(cloudkit: &CloudKitClient) -> Option<Vec<String>> {
    let body = json!({
        "records": [ { "recordName": "default" } ]
    });
    let value = cloudkit
        .post_authenticated("public", "records/lookup", &body)
        .await
        .ok()?;

    let record = value.get("records").and_then(Value::as_array)?.first()?;
    if record.get("serverErrorCode").is_some() {
        return None;
    }
    let list = record
        .get("fields")?
        .get("stunURLs")?
        .get("value")?
        .as_array()?;

    Some(
        list.iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .filter(|s| !s.trim().is_empty())
            .collect(),
    )
}

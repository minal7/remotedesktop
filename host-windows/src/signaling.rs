use crate::cloudkit::{CloudKitClient, CloudKitError};
use anyhow::{anyhow, Context, Result};
use rand::Rng;
use serde_json::{json, Map, Value};
use std::{
    collections::HashSet,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Role {
    Host,
    Client,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Kind {
    Offer,
    Answer,
    Ice,
    Bye,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignalingEnvelope {
    pub role: Role,
    pub kind: Kind,
    pub payload: Map<String, Value>,
    pub ts: u64,
}

#[derive(Clone, Debug)]
pub struct HostSignalingOptions {
    pub code: String,
    pub sender_id: String,
    pub host_name: String,
    pub stale_record_seconds: u64,
}

#[derive(Debug)]
pub struct HostSignalingClient {
    cloudkit: CloudKitClient,
    options: HostSignalingOptions,
    target_id: Option<String>,
    advertisement_record_name: Option<String>,
    owned_record_names: HashSet<String>,
    consumed_record_names: HashSet<String>,
    started_at_ms: u64,
}

impl HostSignalingClient {
    pub fn new(cloudkit: CloudKitClient, options: HostSignalingOptions) -> Self {
        let advertisement_record_name = Some(advertisement_record_name(&options.sender_id));
        Self {
            cloudkit,
            options,
            target_id: None,
            advertisement_record_name,
            owned_record_names: HashSet::new(),
            consumed_record_names: HashSet::new(),
            started_at_ms: now_ms(),
        }
    }

    pub fn code(&self) -> &str {
        &self.options.code
    }

    pub async fn claim(&mut self) -> Result<()> {
        self.write_advertisement()
            .await
            .context("couldn't publish Windows host pairing advertisement")
    }

    pub async fn refresh_advertisement(&mut self) -> Result<()> {
        if self.advertisement_record_name.is_none() {
            self.advertisement_record_name =
                Some(advertisement_record_name(&self.options.sender_id));
            return self
                .write_advertisement()
                .await
                .context("couldn't publish Windows host pairing advertisement");
        }

        if let Err(error) = self.update_advertisement().await {
            warn_refresh_fallback(&error);
            self.advertisement_record_name = None;
            self.write_advertisement().await.context(
                "couldn't recreate Windows host pairing advertisement after refresh failed",
            )?;
        }
        Ok(())
    }

    pub async fn stop_advertising(&mut self) -> Result<()> {
        let Some(record_name) = self.advertisement_record_name.take() else {
            return Ok(());
        };

        let body = json!({
            "operations": [
                {
                    "operationType": "forceDelete",
                    "record": { "recordName": record_name.clone() }
                }
            ],
            "atomic": false
        });

        self.cloudkit
            .post_authenticated("private", "records/modify", &body)
            .await?;
        self.owned_record_names.remove(&record_name);
        Ok(())
    }

    pub async fn poll(&mut self) -> Result<Vec<SignalingEnvelope>> {
        let cutoff_ms = now_ms().saturating_sub(self.options.stale_record_seconds * 1000);
        let min_created_at = cutoff_ms.max(self.started_at_ms);
        let body = json!({
            "zoneID": { "zoneName": "_defaultZone" },
            "resultsLimit": 50,
            "numbersAsStrings": false,
            "query": {
                "recordType": "WebRTCSignal",
                "filterBy": [
                    {
                        "fieldName": "targetID",
                        "comparator": "EQUALS",
                        "fieldValue": string_field(&self.options.sender_id),
                    },
                    {
                        "fieldName": "createdAt",
                        "comparator": "GREATER_THAN",
                        "fieldValue": timestamp_field(min_created_at),
                    }
                ],
                "sortBy": [
                    { "fieldName": "createdAt", "ascending": true }
                ]
            }
        });

        let value = match self
            .cloudkit
            .post_authenticated("private", "records/query", &body)
            .await
        {
            Ok(value) => value,
            Err(CloudKitError::Server { code, .. }) if code == "UNKNOWN_ITEM" => {
                return Ok(Vec::new());
            }
            Err(error) => return Err(error.into()),
        };

        let records = value
            .get("records")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        let mut envelopes = Vec::new();
        for record in records {
            if record.get("serverErrorCode").is_some() {
                continue;
            }
            let Some(record_name) = record.get("recordName").and_then(Value::as_str) else {
                continue;
            };
            if !self.consumed_record_names.insert(record_name.to_string()) {
                continue;
            }
            if let Some(envelope) = self.envelope_from_record(&record) {
                envelopes.push(envelope);
            }
        }

        Ok(envelopes)
    }

    pub async fn send(&mut self, envelope: SignalingEnvelope) -> Result<()> {
        let target_id = self
            .target_id
            .clone()
            .ok_or_else(|| anyhow!("can't send before a client target is known"))?;
        let payload = serde_json::to_string(&envelope.payload)?;
        let body = json!({
            "operations": [
                {
                    "operationType": "create",
                    "record": {
                        "recordType": "WebRTCSignal",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "targetID": string_field(&target_id),
                            "pairingCode": string_field(&self.options.code),
                            "kind": string_field(envelope.kind.as_str()),
                            "payload": string_field(&payload),
                            "createdAt": timestamp_field(now_ms()),
                        }
                    }
                }
            ]
        });

        // Retry through production CloudKit throttling: a dropped ICE
        // candidate here means the iOS client never learns this path and
        // ICE can settle on an unusable pair, stalling DTLS.
        let value = self
            .cloudkit
            .post_authenticated_retrying("private", "records/modify", &body)
            .await?;
        self.record_owned_names(&value)?;
        Ok(())
    }

    pub async fn cleanup(&mut self) -> Result<()> {
        if self.owned_record_names.is_empty() {
            return Ok(());
        }

        let operations: Vec<Value> = self
            .owned_record_names
            .iter()
            .map(|record_name| {
                json!({
                    "operationType": "forceDelete",
                    "record": { "recordName": record_name }
                })
            })
            .collect();

        let body = json!({ "operations": operations, "atomic": false });
        match self
            .cloudkit
            .post_authenticated("private", "records/modify", &body)
            .await
        {
            Ok(_) => {
                self.owned_record_names.clear();
                Ok(())
            }
            Err(error) => Err(error.into()),
        }
    }

    fn envelope_from_record(&mut self, record: &Value) -> Option<SignalingEnvelope> {
        let fields = record.get("fields")?.as_object()?;
        let sender_id = field_string(fields, "senderID")?;
        self.target_id = Some(sender_id.clone());

        let kind = Kind::from_str(&field_string(fields, "kind")?)?;
        let payload_string = field_string(fields, "payload")?;
        let payload = serde_json::from_str::<Map<String, Value>>(&payload_string).ok()?;
        let role = if sender_id == self.options.sender_id {
            Role::Host
        } else {
            Role::Client
        };
        let ts = field_u64(fields, "createdAt").unwrap_or_else(now_ms) / 1000;

        Some(SignalingEnvelope {
            role,
            kind,
            payload,
            ts,
        })
    }

    async fn write_advertisement(&mut self) -> Result<()> {
        let record_name = advertisement_record_name(&self.options.sender_id);
        self.advertisement_record_name = Some(record_name.clone());
        let body = json!({
            "operations": [
                {
                    "operationType": "forceUpdate",
                    "record": {
                        "recordName": record_name,
                        "recordType": "HostAdvertisement",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "pairingCode": string_field(&self.options.code),
                            "hostName": string_field(&self.options.host_name),
                            "createdAt": timestamp_field(now_ms()),
                        }
                    }
                }
            ]
        });

        let value = self
            .cloudkit
            .post_authenticated_retrying("private", "records/modify", &body)
            .await?;
        let names = self.record_owned_names(&value)?;
        if let Some(record_name) = names.into_iter().next() {
            self.advertisement_record_name = Some(record_name);
        }
        Ok(())
    }

    async fn update_advertisement(&mut self) -> Result<()> {
        let record_name = self
            .advertisement_record_name
            .clone()
            .unwrap_or_else(|| advertisement_record_name(&self.options.sender_id));
        self.advertisement_record_name = Some(record_name.clone());
        let body = json!({
            "operations": [
                {
                    "operationType": "forceUpdate",
                    "record": {
                        "recordName": record_name,
                        "recordType": "HostAdvertisement",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "pairingCode": string_field(&self.options.code),
                            "hostName": string_field(&self.options.host_name),
                            "createdAt": timestamp_field(now_ms()),
                        }
                    }
                }
            ]
        });

        let value = self
            .cloudkit
            .post_authenticated_retrying("private", "records/modify", &body)
            .await?;
        let names = self.record_owned_names(&value)?;
        if let Some(record_name) = names.into_iter().next() {
            self.advertisement_record_name = Some(record_name);
        }
        Ok(())
    }

    fn record_owned_names(&mut self, value: &Value) -> Result<Vec<String>> {
        let records = value
            .get("records")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow!("CloudKit modify response did not include records"))?;

        let mut names = Vec::new();
        for record in records {
            if let Some(code) = record.get("serverErrorCode").and_then(Value::as_str) {
                let reason = record
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("CloudKit record operation failed");
                return Err(anyhow!(
                    "CloudKit record operation failed: {code}: {reason}"
                ));
            }
            if let Some(record_name) = record.get("recordName").and_then(Value::as_str) {
                self.owned_record_names.insert(record_name.to_string());
                names.push(record_name.to_string());
            }
        }
        Ok(names)
    }
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Offer => "offer",
            Self::Answer => "answer",
            Self::Ice => "ice",
            Self::Bye => "bye",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "offer" => Some(Self::Offer),
            "answer" => Some(Self::Answer),
            "ice" => Some(Self::Ice),
            "bye" => Some(Self::Bye),
            _ => None,
        }
    }
}

impl SignalingEnvelope {
    pub fn host_answer(payload: Map<String, Value>) -> Self {
        Self {
            role: Role::Host,
            kind: Kind::Answer,
            payload,
            ts: now_ms() / 1000,
        }
    }

    pub fn host_bye(reason: &str) -> Self {
        Self {
            role: Role::Host,
            kind: Kind::Bye,
            payload: Map::from_iter([("reason".to_string(), Value::String(reason.to_string()))]),
            ts: now_ms() / 1000,
        }
    }
}

pub fn new_pairing_code() -> String {
    let code = rand::rng().random_range(0..1_000_000);
    format!("{code:06}")
}

pub fn advertisement_refresh_interval(stale_record_seconds: u64) -> Duration {
    Duration::from_secs((stale_record_seconds.max(1) / 2).clamp(1, 120))
}

pub fn advertisement_record_name(sender_id: &str) -> String {
    let suffix = sender_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("HostAdvertisement-{suffix}")
}

fn warn_refresh_fallback(error: &anyhow::Error) {
    tracing::warn!("CloudKit advertisement refresh failed; recreating record: {error:#}");
}

fn string_field(value: &str) -> Value {
    json!({ "value": value, "type": "STRING" })
}

fn timestamp_field(timestamp_ms: u64) -> Value {
    json!({ "value": timestamp_ms, "type": "TIMESTAMP" })
}

fn field_string(fields: &Map<String, Value>, key: &str) -> Option<String> {
    fields
        .get(key)?
        .get("value")?
        .as_str()
        .map(ToString::to_string)
}

fn field_u64(fields: &Map<String, Value>, key: &str) -> Option<u64> {
    let value = fields.get(key)?.get("value")?;
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|n| u64::try_from(n).ok()))
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_code_is_six_digits() {
        let code = new_pairing_code();
        assert_eq!(code.len(), 6);
        assert!(code.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn timestamp_field_uses_cloudkit_timestamp_type() {
        assert_eq!(
            timestamp_field(1_700_000_000_000),
            json!({ "value": 1_700_000_000_000_u64, "type": "TIMESTAMP" })
        );
    }

    #[test]
    fn advertisement_refresh_interval_stays_inside_stale_window() {
        assert_eq!(
            advertisement_refresh_interval(300),
            Duration::from_secs(120)
        );
        assert_eq!(advertisement_refresh_interval(20), Duration::from_secs(10));
        assert_eq!(advertisement_refresh_interval(0), Duration::from_secs(1));
    }

    #[test]
    fn advertisement_record_name_is_stable_per_sender() {
        assert_eq!(
            advertisement_record_name("host-id"),
            "HostAdvertisement-host-id"
        );
        assert_eq!(
            advertisement_record_name("host id/1"),
            "HostAdvertisement-host_id_1"
        );
    }

    #[test]
    fn parses_signal_record_payload() {
        let cloudkit = CloudKitClient::new(
            crate::config::CloudKitConfig {
                container_identifier: "iCloud.com.example".to_string(),
                environment: crate::config::CloudKitEnvironment::Development,
                api_token: "token".to_string(),
            },
            crate::credentials::CredentialStore::new(),
        );
        let mut client = HostSignalingClient::new(
            cloudkit,
            HostSignalingOptions {
                code: "123456".to_string(),
                sender_id: "host-id".to_string(),
                host_name: "Windows".to_string(),
                stale_record_seconds: 300,
            },
        );
        let record = json!({
            "recordName": "record-1",
            "fields": {
                "senderID": { "value": "client-id" },
                "kind": { "value": "offer" },
                "payload": { "value": "{\"client\":\"iPad\"}" },
                "createdAt": { "value": 1_700_000_000_000_u64 }
            }
        });

        let envelope = client.envelope_from_record(&record).unwrap();
        assert_eq!(envelope.kind, Kind::Offer);
        assert_eq!(client.target_id.as_deref(), Some("client-id"));
        assert_eq!(envelope.payload["client"], "iPad");
    }
}

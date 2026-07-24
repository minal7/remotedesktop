use crate::cloudkit::{CloudKitClient, CloudKitError};
use anyhow::{anyhow, ensure, Context, Result};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, HashSet},
    fs::{File, OpenOptions},
    io::{ErrorKind, Read, Write},
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const QUERY_PAGE_SIZE: usize = 50;
const MAXIMUM_QUERY_RECORDS: usize = 500;
const MAXIMUM_QUERY_PAGES: usize = 10;
const MAXIMUM_CONSUMED_RECORDS: usize = 512;
const MAXIMUM_TRACKED_OWNED_RECORDS: usize = 256;
const MAXIMUM_DELETE_BATCH_SIZE: usize = 100;
const MAXIMUM_LEDGER_BYTES: u64 = 256 * 1024;
const MAXIMUM_RECORD_NAME_BYTES: usize = 128;
const MAXIMUM_CONTINUATION_MARKER_BYTES: usize = 4096;
const SIGNAL_RECORD_PREFIX: &str = "WebRTCSignal-Signaling-";
const OWNED_LEDGER_VERSION: u8 = 1;

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
    /// Short-lived, non-secret routing value retained for compatibility with
    /// the deployed CloudKit `pairingCode` field. It is never shown to or
    /// entered by a person.
    pub routing_binding: String,
    pub sender_id: String,
    pub host_name: String,
    pub stale_record_seconds: u64,
    /// These values scope durable cleanup identities to the exact private
    /// CloudKit database. The authenticated account is added during `claim()`
    /// before any record can be written.
    pub container_identifier: String,
    pub environment: String,
}

#[derive(Debug)]
pub struct HostSignalingClient {
    cloudkit: CloudKitClient,
    options: HostSignalingOptions,
    target_id: Option<String>,
    advertisement_record_name: Option<String>,
    owned_record_ledger: Option<OwnedRecordLedger>,
    cleanup_account_id: Option<String>,
    consumed_record_names: ReplayRetention,
    started_at_ms: u64,
}

impl HostSignalingClient {
    pub fn new(cloudkit: CloudKitClient, options: HostSignalingOptions) -> Self {
        let advertisement_record_name = Some(advertisement_record_name(&options.sender_id));
        let validity_window_ms = options.stale_record_seconds.max(1).saturating_mul(1000);
        Self {
            cloudkit,
            options,
            target_id: None,
            advertisement_record_name,
            owned_record_ledger: None,
            cleanup_account_id: None,
            consumed_record_names: ReplayRetention::new(
                validity_window_ms,
                MAXIMUM_CONSUMED_RECORDS,
            ),
            started_at_ms: now_ms(),
        }
    }

    pub fn routing_binding(&self) -> &str {
        &self.options.routing_binding
    }

    pub async fn claim(&mut self) -> Result<()> {
        self.prepare_owned_record_ledger().await?;
        // A prior process may have exited after persisting a record identity
        // but before deleting it. Cleanup must succeed before this process is
        // allowed to add more private-CloudKit state.
        self.cleanup()
            .await
            .context("couldn't clean up prior Windows signaling records")?;
        self.write_advertisement()
            .await
            .context("couldn't publish Windows host advertisement")
    }

    pub async fn refresh_advertisement(&mut self) -> Result<()> {
        if self.advertisement_record_name.is_none() {
            self.advertisement_record_name =
                Some(advertisement_record_name(&self.options.sender_id));
            return self
                .write_advertisement()
                .await
                .context("couldn't publish Windows host advertisement");
        }

        if let Err(error) = self.update_advertisement().await {
            warn_refresh_fallback(&error);
            self.advertisement_record_name = None;
            self.write_advertisement()
                .await
                .context("couldn't recreate Windows host advertisement after refresh failed")?;
        }
        Ok(())
    }

    pub async fn stop_advertising(&mut self) -> Result<()> {
        let Some(record_name) = self.advertisement_record_name.clone() else {
            return Ok(());
        };
        self.cleanup_record_names(&[record_name]).await?;
        self.advertisement_record_name = None;
        Ok(())
    }

    pub async fn poll(&mut self) -> Result<Vec<SignalingEnvelope>> {
        let observed_at_ms = now_ms();
        let cutoff_ms = observed_at_ms.saturating_sub(
            self.options
                .stale_record_seconds
                .max(1)
                .saturating_mul(1000),
        );
        let min_created_at = cutoff_ms.max(self.started_at_ms);

        // Accumulate every page before decoding or changing replay/target
        // state. Acting on a bounded prefix would let a later, unseen offer
        // alter which client should have been selected.
        let mut accumulator =
            BoundedQueryAccumulator::new(MAXIMUM_QUERY_RECORDS, MAXIMUM_QUERY_PAGES);
        let mut continuation_marker = None;
        loop {
            let body = signaling_query_body(
                &self.options.sender_id,
                min_created_at,
                continuation_marker.as_deref(),
            );
            let value = match self
                .cloudkit
                .post_authenticated("private", "records/query", &body)
                .await
            {
                Ok(value) => value,
                Err(CloudKitError::Server { code, .. })
                    if code == "UNKNOWN_ITEM" && accumulator.is_empty() =>
                {
                    return Ok(Vec::new());
                }
                Err(error) => return Err(error.into()),
            };
            continuation_marker = accumulator.append_page(&value)?;
            if continuation_marker.is_none() {
                break;
            }
        }
        self.consume_poll_records(accumulator.into_records(), observed_at_ms)
    }

    pub async fn send(&mut self, envelope: SignalingEnvelope) -> Result<()> {
        let target_id = self
            .target_id
            .clone()
            .ok_or_else(|| anyhow!("can't send before a client target is known"))?;
        let record_name = format!("{SIGNAL_RECORD_PREFIX}{}", Uuid::new_v4());
        self.reserve_owned_record(&record_name, now_ms(), false)
            .await?;
        let payload = serde_json::to_string(&envelope.payload)?;
        let body = json!({
            "operations": [
                {
                    "operationType": "create",
                    "record": {
                        "recordName": record_name,
                        "recordType": "WebRTCSignal",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "targetID": string_field(&target_id),
                            "pairingCode": string_field(&self.options.routing_binding),
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
        let expected_account = self.cleanup_account_identity()?.to_string();
        let value = self
            .cloudkit
            .post_authenticated_retrying_for_account(
                "private",
                "records/modify",
                &body,
                &expected_account,
            )
            .await?;
        verify_saved_record(&value, &record_name)?;
        Ok(())
    }

    pub async fn cleanup(&mut self) -> Result<()> {
        let record_names = self
            .owned_record_ledger
            .as_ref()
            .map(OwnedRecordLedger::records_for_cleanup)
            .unwrap_or_default();
        if record_names.is_empty() {
            return Ok(());
        }

        let mut first_error = None;
        for batch in record_names.chunks(MAXIMUM_DELETE_BATCH_SIZE) {
            if let Err(error) = self.cleanup_record_names(batch).await {
                if first_error.is_none() {
                    first_error = Some(error);
                }
            }
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        Ok(())
    }

    fn envelope_from_record(&self, record: &Value) -> Option<ParsedSignalRecord> {
        let record_name = record.get("recordName")?.as_str()?;
        if !is_signal_record_name(record_name) {
            return None;
        }
        let fields = record.get("fields")?.as_object()?;
        let routing_binding = field_string(fields, "pairingCode")?;
        if routing_binding != self.options.routing_binding {
            return None;
        }
        if field_string(fields, "targetID")? != self.options.sender_id {
            return None;
        }
        let sender_id = field_string(fields, "senderID")?;
        if sender_id.is_empty()
            || sender_id.len() > MAXIMUM_RECORD_NAME_BYTES
            || sender_id == self.options.sender_id
        {
            return None;
        }

        let kind = Kind::from_str(&field_string(fields, "kind")?)?;
        let payload_string = field_string(fields, "payload")?;
        let payload = serde_json::from_str::<Map<String, Value>>(&payload_string).ok()?;
        let created_at_ms = field_u64(fields, "createdAt")?;

        Some(ParsedSignalRecord {
            record_name: record_name.to_string(),
            sender_id,
            created_at_ms,
            envelope: SignalingEnvelope {
                role: Role::Client,
                kind,
                payload,
                ts: created_at_ms / 1000,
            },
        })
    }

    fn consume_poll_records(
        &mut self,
        records: Vec<Value>,
        observed_at_ms: u64,
    ) -> Result<Vec<SignalingEnvelope>> {
        let mut decoded = records
            .iter()
            .filter_map(|record| {
                let record_name = record.get("recordName")?.as_str()?;
                if self
                    .consumed_record_names
                    .contains(record_name, observed_at_ms)
                {
                    return None;
                }
                // Decode the complete record before reserving replay state.
                // A malformed or differently-bound record must not consume a
                // bounded slot or gain the ability to establish the peer.
                self.envelope_from_record(record)
            })
            .collect::<Vec<_>>();
        decoded.sort_by(|left, right| {
            left.created_at_ms
                .cmp(&right.created_at_ms)
                .then_with(|| left.record_name.cmp(&right.record_name))
                .then_with(|| left.sender_id.cmp(&right.sender_id))
        });

        let selected_offer_index;
        let selected_sender_id = if let Some(target_id) = self.target_id.clone() {
            selected_offer_index = None;
            Some(target_id)
        } else {
            selected_offer_index = decoded
                .iter()
                .position(|record| record.envelope.kind == Kind::Offer);
            selected_offer_index.map(|index| decoded[index].sender_id.clone())
        };

        let Some(selected_sender_id) = selected_sender_id else {
            // ICE can legitimately arrive before its offer. Leave all valid
            // records unconsumed until an offer makes sender selection safe.
            return Ok(Vec::new());
        };

        // Apply replay reservations transactionally so capacity pressure does
        // not leave a partially consumed batch or a half-established target.
        let mut next_retention = self.consumed_record_names.clone();
        let mut envelopes = Vec::new();
        for (index, record) in decoded.into_iter().enumerate() {
            ensure!(
                next_retention.reserve(&record.record_name, record.created_at_ms, observed_at_ms),
                "too many live signaling records for bounded replay retention"
            );
            if record.sender_id != selected_sender_id {
                continue;
            }
            if selected_offer_index.is_some_and(|offer_index| index < offer_index)
                && record.envelope.kind != Kind::Ice
            {
                continue;
            }
            if record.envelope.kind == Kind::Answer {
                // A client answer is never meaningful to a host and cannot be
                // allowed to influence the selected reply target.
                continue;
            }
            envelopes.push(record.envelope);
        }

        self.consumed_record_names = next_retention;
        if self.target_id.is_none() {
            self.target_id = Some(selected_sender_id);
        }
        Ok(envelopes)
    }

    async fn prepare_owned_record_ledger(&mut self) -> Result<()> {
        if self.owned_record_ledger.is_some() {
            return Ok(());
        }
        ensure!(
            Uuid::parse_str(&self.options.sender_id)
                .map(|value| value.hyphenated().to_string() == self.options.sender_id)
                .unwrap_or(false),
            "Windows host sender identity is not a canonical UUID"
        );
        ensure!(
            self.options.routing_binding.len() == 6
                && self
                    .options
                    .routing_binding
                    .bytes()
                    .all(|byte| byte.is_ascii_digit()),
            "Windows host routing binding is malformed"
        );
        ensure!(
            !self.options.container_identifier.is_empty() && !self.options.environment.is_empty(),
            "Windows host CloudKit cleanup scope is incomplete"
        );
        ensure!(
            !self.options.container_identifier.contains('\n')
                && !self.options.environment.contains('\n'),
            "Windows host CloudKit cleanup scope is malformed"
        );
        let user = self
            .cloudkit
            .current_user()
            .await
            .context("couldn't identify the CloudKit account for signaling cleanup")?;
        ensure!(
            !user.user_record_name.is_empty(),
            "CloudKit returned an empty account identity"
        );
        let retention = owned_record_retention(
            &self.options.container_identifier,
            &self.options.environment,
            &self.options.sender_id,
            &user.user_record_name,
        )?;
        let ledger = OwnedRecordLedger::open(
            retention,
            advertisement_record_name(&self.options.sender_id),
            self.options
                .stale_record_seconds
                .max(1)
                .saturating_mul(1000),
            MAXIMUM_TRACKED_OWNED_RECORDS,
        )
        .context("couldn't restore durable Windows signaling cleanup identities")?;
        self.owned_record_ledger = Some(ledger);
        self.cleanup_account_id = Some(user.user_record_name);
        Ok(())
    }

    async fn verify_cleanup_account(&self) -> Result<()> {
        self.cloudkit
            .revalidate_current_user(self.cleanup_account_identity()?)
            .await
            .context("couldn't revalidate the CloudKit cleanup account")
    }

    fn cleanup_account_identity(&self) -> Result<&str> {
        self.cleanup_account_id
            .as_deref()
            .ok_or_else(|| anyhow!("signaling cleanup account was not prepared"))
    }

    async fn reserve_owned_record(
        &mut self,
        record_name: &str,
        created_at_ms: u64,
        refreshes_deadline: bool,
    ) -> Result<()> {
        loop {
            let reservation = self
                .owned_record_ledger
                .as_mut()
                .ok_or_else(|| anyhow!("signaling cleanup ledger was not prepared"))?
                .reserve(record_name, created_at_ms, refreshes_deadline)?;
            match reservation {
                OwnedRecordReservation::Tracked => return Ok(()),
                OwnedRecordReservation::CleanupRequired(record_names) => {
                    self.cleanup_record_names(&record_names).await?;
                }
            }
        }
    }

    async fn cleanup_record_names(&mut self, record_names: &[String]) -> Result<()> {
        if record_names.is_empty() {
            return Ok(());
        }
        ensure!(
            record_names.len() <= MAXIMUM_DELETE_BATCH_SIZE,
            "CloudKit cleanup batch exceeded its hard bound"
        );
        let expected = record_names.iter().cloned().collect::<HashSet<_>>();
        ensure!(
            expected.len() == record_names.len(),
            "CloudKit cleanup batch contained duplicate identities"
        );
        let operations = record_names
            .iter()
            .map(|record_name| {
                json!({
                    "operationType": "forceDelete",
                    "record": { "recordName": record_name }
                })
            })
            .collect::<Vec<_>>();
        let body = json!({ "operations": operations, "atomic": false });
        let expected_account = self.cleanup_account_identity()?.to_string();
        let value = self
            .cloudkit
            .post_authenticated_for_account("private", "records/modify", &body, &expected_account)
            .await?;
        let accounting = account_delete_response(&value, &expected)?;

        if !accounting.confirmed.is_empty() {
            // A token can rotate while the delete request is in flight. Do
            // not release durable prior-account identities until the account
            // is checked again immediately before the local ledger mutation.
            self.verify_cleanup_account().await?;
            self.owned_record_ledger
                .as_mut()
                .ok_or_else(|| anyhow!("signaling cleanup ledger was not prepared"))?
                .mark_cleaned(&accounting.confirmed)?;
        }
        ensure!(
            accounting.failed.is_empty(),
            "CloudKit did not confirm deletion of signaling records: {}",
            accounting.failed.join(", ")
        );
        Ok(())
    }

    async fn write_advertisement(&mut self) -> Result<()> {
        let record_name = advertisement_record_name(&self.options.sender_id);
        self.advertisement_record_name = Some(record_name.clone());
        self.reserve_owned_record(&record_name, now_ms(), true)
            .await?;
        let body = json!({
            "operations": [
                {
                    "operationType": "forceUpdate",
                    "record": {
                        "recordName": record_name,
                        "recordType": "HostAdvertisement",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "pairingCode": string_field(&self.options.routing_binding),
                            "hostName": string_field(&self.options.host_name),
                            "createdAt": timestamp_field(now_ms()),
                        }
                    }
                }
            ]
        });

        let expected_account = self.cleanup_account_identity()?.to_string();
        let value = self
            .cloudkit
            .post_authenticated_retrying_for_account(
                "private",
                "records/modify",
                &body,
                &expected_account,
            )
            .await?;
        verify_saved_record(&value, &record_name)?;
        Ok(())
    }

    async fn update_advertisement(&mut self) -> Result<()> {
        let record_name = self
            .advertisement_record_name
            .clone()
            .unwrap_or_else(|| advertisement_record_name(&self.options.sender_id));
        self.advertisement_record_name = Some(record_name.clone());
        self.reserve_owned_record(&record_name, now_ms(), true)
            .await?;
        let body = json!({
            "operations": [
                {
                    "operationType": "forceUpdate",
                    "record": {
                        "recordName": record_name,
                        "recordType": "HostAdvertisement",
                        "fields": {
                            "senderID": string_field(&self.options.sender_id),
                            "pairingCode": string_field(&self.options.routing_binding),
                            "hostName": string_field(&self.options.host_name),
                            "createdAt": timestamp_field(now_ms()),
                        }
                    }
                }
            ]
        });

        let expected_account = self.cleanup_account_identity()?.to_string();
        let value = self
            .cloudkit
            .post_authenticated_retrying_for_account(
                "private",
                "records/modify",
                &body,
                &expected_account,
            )
            .await?;
        verify_saved_record(&value, &record_name)?;
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct ParsedSignalRecord {
    record_name: String,
    sender_id: String,
    created_at_ms: u64,
    envelope: SignalingEnvelope,
}

#[derive(Clone, Debug)]
struct ReplayRetention {
    validity_window_ms: u64,
    maximum_entries: usize,
    entries: HashMap<String, u64>,
}

impl ReplayRetention {
    fn new(validity_window_ms: u64, maximum_entries: usize) -> Self {
        debug_assert!(validity_window_ms > 0);
        debug_assert!(maximum_entries > 0);
        Self {
            validity_window_ms,
            maximum_entries,
            entries: HashMap::new(),
        }
    }

    fn contains(&mut self, record_name: &str, observed_at_ms: u64) -> bool {
        self.prune(observed_at_ms);
        self.entries.contains_key(record_name)
    }

    fn reserve(&mut self, record_name: &str, created_at_ms: u64, observed_at_ms: u64) -> bool {
        self.prune(observed_at_ms);
        if self.entries.contains_key(record_name) {
            return true;
        }
        if self.entries.len() >= self.maximum_entries {
            return false;
        }
        let maximum_expiry = observed_at_ms.saturating_add(self.validity_window_ms);
        let requested_expiry = created_at_ms.saturating_add(self.validity_window_ms);
        let expires_at_ms = requested_expiry.max(observed_at_ms).min(maximum_expiry);
        self.entries.insert(record_name.to_string(), expires_at_ms);
        true
    }

    fn prune(&mut self, observed_at_ms: u64) {
        self.entries
            .retain(|_, expires_at_ms| *expires_at_ms > observed_at_ms);
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

#[derive(Debug)]
struct BoundedQueryAccumulator {
    maximum_records: usize,
    maximum_pages: usize,
    observed_pages: usize,
    records: Vec<Value>,
    seen_markers: HashSet<String>,
}

impl BoundedQueryAccumulator {
    fn new(maximum_records: usize, maximum_pages: usize) -> Self {
        debug_assert!(maximum_records > 0);
        debug_assert!(maximum_pages > 0);
        Self {
            maximum_records,
            maximum_pages,
            observed_pages: 0,
            records: Vec::new(),
            seen_markers: HashSet::new(),
        }
    }

    fn is_empty(&self) -> bool {
        self.observed_pages == 0
    }

    fn append_page(&mut self, value: &Value) -> Result<Option<String>> {
        let records = value
            .get("records")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow!("CloudKit query response did not include a records array"))?;
        ensure!(
            records.len() <= QUERY_PAGE_SIZE,
            "CloudKit query page exceeded the requested record limit"
        );
        for record in records {
            if let Some(code) = record.get("serverErrorCode").and_then(Value::as_str) {
                let reason = record
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("CloudKit record query failed");
                return Err(anyhow!(
                    "CloudKit returned an incomplete signaling page: {code}: {reason}"
                ));
            }
        }

        let marker = match value.get("continuationMarker") {
            None | Some(Value::Null) => None,
            Some(Value::String(marker)) if !marker.is_empty() => {
                ensure!(
                    marker.len() <= MAXIMUM_CONTINUATION_MARKER_BYTES,
                    "CloudKit continuation marker exceeded its hard bound"
                );
                ensure!(
                    !self.seen_markers.contains(marker),
                    "CloudKit repeated a signaling continuation marker"
                );
                Some(marker.clone())
            }
            Some(_) => {
                return Err(anyhow!(
                    "CloudKit returned an invalid signaling continuation marker"
                ));
            }
        };
        if value
            .get("moreComing")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            && marker.is_none()
        {
            return Err(anyhow!(
                "CloudKit reported more signaling records without a continuation marker"
            ));
        }

        let next_pages = self.observed_pages.saturating_add(1);
        let next_records = self
            .records
            .len()
            .checked_add(records.len())
            .ok_or_else(|| anyhow!("CloudKit signaling record count overflowed"))?;
        ensure!(
            next_pages <= self.maximum_pages && next_records <= self.maximum_records,
            "CloudKit signaling query exceeded its hard bound"
        );
        ensure!(
            marker.is_none()
                || (next_pages < self.maximum_pages && next_records < self.maximum_records),
            "CloudKit signaling query was incomplete at its hard bound"
        );

        self.observed_pages = next_pages;
        self.records.extend(records.iter().cloned());
        if let Some(marker) = &marker {
            self.seen_markers.insert(marker.clone());
        }
        Ok(marker)
    }

    fn into_records(self) -> Vec<Value> {
        self.records
    }
}

#[derive(Clone, Debug)]
struct OwnedRecordRetention {
    binding: String,
    path: PathBuf,
}

fn owned_record_retention(
    container_identifier: &str,
    environment: &str,
    sender_id: &str,
    account_id: &str,
) -> Result<OwnedRecordRetention> {
    ensure!(
        !account_id.contains('\n'),
        "CloudKit account identity is malformed"
    );
    let binding = format!(
        "RemoteDesktop.WindowsOwnedCloudKitRecords.v1\n{container_identifier}\n{environment}\n{sender_id}\n{account_id}"
    );
    let hash = fnv1a64(binding.as_bytes());
    let base = std::env::var_os("LOCALAPPDATA")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("LOCALAPPDATA is unavailable for durable signaling cleanup"))?
        .join("RemoteDesktopHost");
    Ok(OwnedRecordRetention {
        binding,
        path: base.join(format!("cloudkit-signaling-owned-{hash:016x}.json")),
    })
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct TrackedOwnedRecord {
    record_name: String,
    delete_after_ms: u64,
}

#[derive(Debug, Deserialize, Serialize)]
struct StoredOwnedRecordLedger {
    version: u8,
    binding: String,
    records: Vec<TrackedOwnedRecord>,
}

#[derive(Debug)]
struct OwnedRecordLedger {
    retention: OwnedRecordRetention,
    advertisement_record_name: String,
    validity_window_ms: u64,
    maximum_entries: usize,
    records: HashMap<String, TrackedOwnedRecord>,
}

#[derive(Debug, Eq, PartialEq)]
enum OwnedRecordReservation {
    Tracked,
    CleanupRequired(Vec<String>),
}

impl OwnedRecordLedger {
    fn open(
        retention: OwnedRecordRetention,
        advertisement_record_name: String,
        validity_window_ms: u64,
        maximum_entries: usize,
    ) -> Result<Self> {
        ensure!(validity_window_ms > 0, "cleanup validity window is empty");
        ensure!(maximum_entries > 0, "cleanup retention capacity is empty");
        ensure!(
            retention.binding.len() <= 4096,
            "cleanup account binding exceeded its hard bound"
        );
        let mut records = HashMap::new();
        match File::open(&retention.path) {
            Ok(file) => {
                let file_length = file.metadata()?.len();
                ensure!(
                    file_length <= MAXIMUM_LEDGER_BYTES,
                    "signaling cleanup ledger exceeded its hard byte bound"
                );
                let mut bytes = Vec::with_capacity(file_length as usize);
                file.take(MAXIMUM_LEDGER_BYTES.saturating_add(1))
                    .read_to_end(&mut bytes)?;
                ensure!(
                    bytes.len() as u64 <= MAXIMUM_LEDGER_BYTES,
                    "signaling cleanup ledger exceeded its hard byte bound"
                );
                let stored: StoredOwnedRecordLedger = serde_json::from_slice(&bytes)
                    .context("signaling cleanup ledger was unreadable")?;
                ensure!(
                    stored.version == OWNED_LEDGER_VERSION && stored.binding == retention.binding,
                    "signaling cleanup ledger did not match this CloudKit account"
                );
                ensure!(
                    stored.records.len() <= maximum_entries,
                    "signaling cleanup ledger exceeded its hard entry bound"
                );
                let maximum_expiry = now_ms().saturating_add(validity_window_ms);
                for mut record in stored.records {
                    ensure!(
                        is_owned_record_name(&record.record_name, &advertisement_record_name),
                        "signaling cleanup ledger contained an unowned record identity"
                    );
                    record.delete_after_ms = record.delete_after_ms.min(maximum_expiry);
                    ensure!(
                        records.insert(record.record_name.clone(), record).is_none(),
                        "signaling cleanup ledger contained duplicate record identities"
                    );
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let ledger = Self {
            retention,
            advertisement_record_name,
            validity_window_ms,
            maximum_entries,
            records,
        };
        // Persist even an empty first-run ledger so failure to create the
        // durable store is detected before any CloudKit write.
        ledger.persist(&ledger.records)?;
        Ok(ledger)
    }

    fn reserve(
        &mut self,
        record_name: &str,
        created_at_ms: u64,
        refreshes_deadline: bool,
    ) -> Result<OwnedRecordReservation> {
        ensure!(
            is_owned_record_name(record_name, &self.advertisement_record_name),
            "refusing to track an unowned CloudKit record identity"
        );
        let now = now_ms();
        let maximum_expiry = now.saturating_add(self.validity_window_ms);
        let candidate_expiry = created_at_ms
            .saturating_add(self.validity_window_ms)
            .max(now)
            .min(maximum_expiry);

        if let Some(existing) = self.records.get(record_name) {
            let delete_after_ms = if refreshes_deadline {
                existing.delete_after_ms.max(candidate_expiry)
            } else {
                existing.delete_after_ms.min(candidate_expiry)
            };
            let mut updated = self.records.clone();
            updated.insert(
                record_name.to_string(),
                TrackedOwnedRecord {
                    record_name: record_name.to_string(),
                    delete_after_ms,
                },
            );
            self.persist(&updated)?;
            self.records = updated;
            return Ok(OwnedRecordReservation::Tracked);
        }

        if self.records.len() >= self.maximum_entries {
            let required = self.records.len() - self.maximum_entries + 1;
            return Ok(OwnedRecordReservation::CleanupRequired(
                self.sorted_records()
                    .into_iter()
                    .take(required)
                    .map(|record| record.record_name)
                    .collect(),
            ));
        }

        let mut updated = self.records.clone();
        updated.insert(
            record_name.to_string(),
            TrackedOwnedRecord {
                record_name: record_name.to_string(),
                delete_after_ms: candidate_expiry,
            },
        );
        // The reservation is durable before its corresponding CloudKit save.
        self.persist(&updated)?;
        self.records = updated;
        Ok(OwnedRecordReservation::Tracked)
    }

    fn records_for_cleanup(&self) -> Vec<String> {
        self.sorted_records()
            .into_iter()
            .map(|record| record.record_name)
            .collect()
    }

    fn mark_cleaned(&mut self, record_names: &HashSet<String>) -> Result<()> {
        let mut updated = self.records.clone();
        for record_name in record_names {
            updated.remove(record_name);
        }
        self.persist(&updated)?;
        self.records = updated;
        Ok(())
    }

    fn sorted_records(&self) -> Vec<TrackedOwnedRecord> {
        let mut records = self.records.values().cloned().collect::<Vec<_>>();
        records.sort_by(|left, right| {
            left.delete_after_ms
                .cmp(&right.delete_after_ms)
                .then_with(|| left.record_name.cmp(&right.record_name))
        });
        records
    }

    fn persist(&self, records: &HashMap<String, TrackedOwnedRecord>) -> Result<()> {
        let mut values = records.values().cloned().collect::<Vec<_>>();
        values.sort_by(|left, right| {
            left.delete_after_ms
                .cmp(&right.delete_after_ms)
                .then_with(|| left.record_name.cmp(&right.record_name))
        });
        let bytes = serde_json::to_vec(&StoredOwnedRecordLedger {
            version: OWNED_LEDGER_VERSION,
            binding: self.retention.binding.clone(),
            records: values,
        })?;
        ensure!(
            bytes.len() as u64 <= MAXIMUM_LEDGER_BYTES,
            "signaling cleanup ledger exceeded its hard byte bound"
        );
        let parent = self
            .retention
            .path
            .parent()
            .ok_or_else(|| anyhow!("signaling cleanup ledger path had no parent"))?;
        std::fs::create_dir_all(parent)?;
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.retention.path)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        Ok(())
    }
}

#[derive(Debug)]
struct DeleteAccounting {
    confirmed: HashSet<String>,
    failed: Vec<String>,
}

fn account_delete_response(value: &Value, expected: &HashSet<String>) -> Result<DeleteAccounting> {
    let records = value
        .get("records")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("CloudKit delete response did not include records"))?;
    let mut confirmed = HashSet::new();
    let mut failed = Vec::new();
    let mut observed = HashSet::new();
    for record in records {
        let record_name = record
            .get("recordName")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("CloudKit delete response omitted a record identity"))?;
        ensure!(
            expected.contains(record_name),
            "CloudKit delete response included an unexpected record identity"
        );
        ensure!(
            observed.insert(record_name.to_string()),
            "CloudKit delete response duplicated a record identity"
        );
        match record.get("serverErrorCode").and_then(Value::as_str) {
            None | Some("UNKNOWN_ITEM") => {
                confirmed.insert(record_name.to_string());
            }
            Some(code) => failed.push(format!("{record_name} ({code})")),
        }
    }
    for missing in expected.difference(&observed) {
        failed.push(format!("{missing} (missing response)"));
    }
    failed.sort();
    Ok(DeleteAccounting { confirmed, failed })
}

fn verify_saved_record(value: &Value, expected_record_name: &str) -> Result<()> {
    let records = value
        .get("records")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("CloudKit modify response did not include records"))?;
    ensure!(
        records.len() == 1,
        "CloudKit returned an unexpected signaling modify result count"
    );
    let record = &records[0];
    if let Some(code) = record.get("serverErrorCode").and_then(Value::as_str) {
        let reason = record
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("CloudKit record operation failed");
        return Err(anyhow!(
            "CloudKit record operation failed: {code}: {reason}"
        ));
    }
    ensure!(
        record.get("recordName").and_then(Value::as_str) == Some(expected_record_name),
        "CloudKit did not confirm the expected signaling record identity"
    );
    Ok(())
}

fn is_signal_record_name(record_name: &str) -> bool {
    if record_name.len() > MAXIMUM_RECORD_NAME_BYTES {
        return false;
    }
    let Some(suffix) = record_name.strip_prefix(SIGNAL_RECORD_PREFIX) else {
        return false;
    };
    Uuid::parse_str(suffix)
        .map(|uuid| uuid.hyphenated().to_string().eq_ignore_ascii_case(suffix))
        .unwrap_or(false)
}

fn is_owned_record_name(record_name: &str, advertisement_name: &str) -> bool {
    record_name == advertisement_name || is_signal_record_name(record_name)
}

fn signaling_query_body(
    sender_id: &str,
    min_created_at: u64,
    continuation_marker: Option<&str>,
) -> Value {
    let mut body = json!({
        "zoneID": { "zoneName": "_defaultZone" },
        "resultsLimit": QUERY_PAGE_SIZE,
        "numbersAsStrings": false,
        "query": {
            "recordType": "WebRTCSignal",
            "filterBy": [
                {
                    "fieldName": "targetID",
                    "comparator": "EQUALS",
                    "fieldValue": string_field(sender_id),
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
    if let Some(marker) = continuation_marker {
        body.as_object_mut()
            .expect("query body is an object")
            .insert(
                "continuationMarker".to_string(),
                Value::String(marker.to_string()),
            );
    }
    body
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

pub fn new_routing_binding() -> String {
    let binding = rand::rng().random_range(0..1_000_000);
    format!("{binding:06}")
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

    const HOST_ID: &str = "4f5f0acf-6e50-4e12-aa0b-59754254d42d";
    const CLIENT_A: &str = "client-a";
    const CLIENT_B: &str = "client-b";

    fn test_client() -> HostSignalingClient {
        let cloudkit = CloudKitClient::new(
            crate::config::CloudKitConfig {
                container_identifier: "iCloud.com.example".to_string(),
                environment: crate::config::CloudKitEnvironment::Development,
                api_token: "token".to_string(),
            },
            crate::credentials::CredentialStore::new("iCloud.com.example", "development").unwrap(),
        );
        HostSignalingClient::new(
            cloudkit,
            HostSignalingOptions {
                routing_binding: "123456".to_string(),
                sender_id: HOST_ID.to_string(),
                host_name: "Windows".to_string(),
                stale_record_seconds: 300,
                container_identifier: "iCloud.com.example".to_string(),
                environment: "development".to_string(),
            },
        )
    }

    fn signal_record(
        uuid_suffix: u32,
        sender_id: &str,
        kind: &str,
        marker: &str,
        created_at_ms: u64,
    ) -> Value {
        let record_name =
            format!("{SIGNAL_RECORD_PREFIX}00000000-0000-0000-0000-{uuid_suffix:012x}");
        json!({
            "recordName": record_name,
            "fields": {
                "senderID": { "value": sender_id },
                "targetID": { "value": HOST_ID },
                "pairingCode": { "value": "123456" },
                "kind": { "value": kind },
                "payload": {
                    "value": serde_json::to_string(&json!({ "marker": marker })).unwrap()
                },
                "createdAt": { "value": created_at_ms }
            }
        })
    }

    struct TemporaryLedger {
        directory: PathBuf,
        retention: OwnedRecordRetention,
    }

    impl TemporaryLedger {
        fn new(binding: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "remote-desktop-windows-signaling-test-{}",
                Uuid::new_v4()
            ));
            Self {
                retention: OwnedRecordRetention {
                    binding: binding.to_string(),
                    path: directory.join("owned.json"),
                },
                directory,
            }
        }
    }

    impl Drop for TemporaryLedger {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.retention.path);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }

    #[test]
    fn routing_binding_matches_deployed_schema_shape() {
        let binding = new_routing_binding();
        assert_eq!(binding.len(), 6);
        assert!(binding.chars().all(|c| c.is_ascii_digit()));
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
    fn validates_signal_before_consuming_or_selecting_target() {
        let mut client = test_client();
        let valid = signal_record(1, CLIENT_A, "offer", "valid", 1_700_000_000_000);
        let parsed = client.envelope_from_record(&valid).unwrap();

        assert_eq!(parsed.envelope.kind, Kind::Offer);
        assert_eq!(parsed.envelope.payload["marker"], "valid");
        assert_eq!(client.target_id, None);
        assert_eq!(client.consumed_record_names.len(), 0);

        let mut malformed = signal_record(2, CLIENT_B, "offer", "malformed", 1_700_000_000_001);
        malformed["fields"]["payload"]["value"] = Value::String("not json".to_string());
        assert!(client.envelope_from_record(&malformed).is_none());
        let envelopes = client
            .consume_poll_records(vec![malformed], 1_700_000_000_002)
            .unwrap();
        assert!(envelopes.is_empty());
        assert_eq!(client.target_id, None);
        assert_eq!(client.consumed_record_names.len(), 0);
    }

    #[test]
    fn ignores_different_binding_without_consuming_or_selecting() {
        let mut client = test_client();
        let mut record = signal_record(1, CLIENT_A, "offer", "wrong-binding", 100);
        record["fields"]["pairingCode"]["value"] = Value::String("654321".to_string());

        assert!(client.envelope_from_record(&record).is_none());
        assert!(client
            .consume_poll_records(vec![record], 101)
            .unwrap()
            .is_empty());
        assert_eq!(client.target_id, None);
        assert_eq!(client.consumed_record_names.len(), 0);
    }

    #[test]
    fn first_offer_selection_is_deterministic_and_target_stays_pinned() {
        let mut client = test_client();
        let first_batch = vec![
            signal_record(4, CLIENT_B, "ice", "b-ice", 102),
            signal_record(2, CLIENT_B, "offer", "b-offer", 101),
            signal_record(3, CLIENT_A, "ice", "a-ice", 102),
            signal_record(1, CLIENT_A, "offer", "a-offer", 101),
        ];
        let envelopes = client.consume_poll_records(first_batch, 103).unwrap();

        assert_eq!(client.target_id.as_deref(), Some(CLIENT_A));
        assert_eq!(
            envelopes
                .iter()
                .map(|envelope| envelope.payload["marker"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["a-offer", "a-ice"]
        );

        let second_batch = vec![
            signal_record(5, CLIENT_B, "offer", "b-redirect", 99),
            signal_record(6, CLIENT_B, "ice", "b-redirect-ice", 104),
            signal_record(7, CLIENT_A, "ice", "a-next-ice", 104),
        ];
        let envelopes = client.consume_poll_records(second_batch, 105).unwrap();
        assert_eq!(client.target_id.as_deref(), Some(CLIENT_A));
        assert_eq!(envelopes.len(), 1);
        assert_eq!(envelopes[0].payload["marker"], "a-next-ice");
    }

    #[test]
    fn answer_or_ice_cannot_establish_a_reply_target() {
        let mut client = test_client();
        let records = vec![
            signal_record(1, CLIENT_A, "answer", "answer", 100),
            signal_record(2, CLIENT_B, "ice", "ice", 101),
        ];

        assert!(client
            .consume_poll_records(records, 102)
            .unwrap()
            .is_empty());
        assert_eq!(client.target_id, None);
        assert_eq!(client.consumed_record_names.len(), 0);
    }

    #[test]
    fn replay_retention_is_bounded_without_evicting_live_identities() {
        let mut retention = ReplayRetention::new(100, 2);
        assert!(retention.reserve("one", 10, 10));
        assert!(retention.reserve("two", 11, 11));
        assert!(!retention.reserve("three", 12, 12));
        assert_eq!(retention.len(), 2);
        assert!(retention.contains("one", 50));

        assert!(retention.reserve("three", 200, 200));
        assert_eq!(retention.len(), 1);
        assert!(retention.contains("three", 200));
    }

    #[test]
    fn replay_capacity_failure_does_not_partially_pin_or_consume_a_batch() {
        let mut client = test_client();
        client.consumed_record_names = ReplayRetention::new(300_000, 1);
        let records = vec![
            signal_record(1, CLIENT_A, "offer", "offer", 100),
            signal_record(2, CLIENT_A, "ice", "ice", 101),
        ];

        assert!(client.consume_poll_records(records, 102).is_err());
        assert_eq!(client.target_id, None);
        assert_eq!(client.consumed_record_names.len(), 0);
    }

    #[test]
    fn bounded_query_rejects_an_incomplete_prefix_at_page_limit() {
        let mut accumulator = BoundedQueryAccumulator::new(10, 2);
        assert_eq!(
            accumulator
                .append_page(&json!({
                    "records": [signal_record(1, CLIENT_A, "offer", "one", 1)],
                    "continuationMarker": "page-2"
                }))
                .unwrap(),
            Some("page-2".to_string())
        );
        let error = accumulator
            .append_page(&json!({
                "records": [signal_record(2, CLIENT_A, "ice", "two", 2)],
                "continuationMarker": "page-3"
            }))
            .unwrap_err();
        assert!(error.to_string().contains("incomplete at its hard bound"));
    }

    #[test]
    fn bounded_query_rejects_repeated_markers_and_partial_record_errors() {
        let mut repeated = BoundedQueryAccumulator::new(10, 3);
        repeated
            .append_page(&json!({ "records": [], "continuationMarker": "same" }))
            .unwrap();
        assert!(repeated
            .append_page(&json!({ "records": [], "continuationMarker": "same" }))
            .unwrap_err()
            .to_string()
            .contains("repeated"));

        let mut partial = BoundedQueryAccumulator::new(10, 3);
        assert!(partial
            .append_page(&json!({
                "records": [{
                    "recordName": "failed",
                    "serverErrorCode": "TRY_AGAIN_LATER",
                    "reason": "retry"
                }]
            }))
            .unwrap_err()
            .to_string()
            .contains("incomplete signaling page"));
        assert!(partial.is_empty());
    }

    #[test]
    fn continuation_marker_is_sent_at_the_query_top_level() {
        let first = signaling_query_body(HOST_ID, 123, None);
        assert_eq!(first["resultsLimit"], QUERY_PAGE_SIZE);
        assert!(first.get("continuationMarker").is_none());

        let continued = signaling_query_body(HOST_ID, 123, Some("opaque-cursor"));
        assert_eq!(continued["continuationMarker"], "opaque-cursor");
        assert_eq!(
            continued["query"]["filterBy"][0]["fieldValue"]["value"],
            HOST_ID
        );
    }

    #[test]
    fn owned_record_identity_is_persisted_and_restored_before_cloud_write() {
        let temporary = TemporaryLedger::new("account-scope");
        let advertisement = advertisement_record_name(HOST_ID);
        let signal_name = format!("{SIGNAL_RECORD_PREFIX}00000000-0000-0000-0000-000000000001");
        {
            let mut ledger = OwnedRecordLedger::open(
                temporary.retention.clone(),
                advertisement.clone(),
                300_000,
                2,
            )
            .unwrap();
            assert_eq!(
                ledger.reserve(&signal_name, now_ms(), false).unwrap(),
                OwnedRecordReservation::Tracked
            );
            assert_eq!(ledger.records_for_cleanup(), vec![signal_name.clone()]);
        }

        let restored =
            OwnedRecordLedger::open(temporary.retention.clone(), advertisement, 300_000, 2)
                .unwrap();
        assert_eq!(restored.records_for_cleanup(), vec![signal_name]);
    }

    #[test]
    fn owned_record_ledger_is_a_bounded_write_barrier() {
        let temporary = TemporaryLedger::new("account-scope");
        let advertisement = advertisement_record_name(HOST_ID);
        let first = format!("{SIGNAL_RECORD_PREFIX}00000000-0000-0000-0000-000000000001");
        let second = format!("{SIGNAL_RECORD_PREFIX}00000000-0000-0000-0000-000000000002");
        let mut ledger =
            OwnedRecordLedger::open(temporary.retention.clone(), advertisement, 300_000, 1)
                .unwrap();
        assert_eq!(
            ledger.reserve(&first, now_ms(), false).unwrap(),
            OwnedRecordReservation::Tracked
        );
        assert_eq!(
            ledger.reserve(&second, now_ms(), false).unwrap(),
            OwnedRecordReservation::CleanupRequired(vec![first.clone()])
        );
        assert_eq!(ledger.records_for_cleanup(), vec![first]);
    }

    #[test]
    fn corrupt_or_wrong_account_cleanup_ledger_fails_closed() {
        let temporary = TemporaryLedger::new("account-a");
        let advertisement = advertisement_record_name(HOST_ID);
        OwnedRecordLedger::open(
            temporary.retention.clone(),
            advertisement.clone(),
            300_000,
            2,
        )
        .unwrap();

        let wrong_account = OwnedRecordRetention {
            binding: "account-b".to_string(),
            path: temporary.retention.path.clone(),
        };
        assert!(OwnedRecordLedger::open(wrong_account, advertisement.clone(), 300_000, 2).is_err());

        std::fs::write(&temporary.retention.path, b"{not json").unwrap();
        assert!(
            OwnedRecordLedger::open(temporary.retention.clone(), advertisement, 300_000, 2)
                .is_err()
        );
    }

    #[test]
    fn partial_delete_accounting_only_releases_confirmed_or_missing_records() {
        let expected = ["one", "two", "three"]
            .into_iter()
            .map(str::to_string)
            .collect::<HashSet<_>>();
        let accounting = account_delete_response(
            &json!({
                "records": [
                    { "recordName": "one" },
                    { "recordName": "two", "serverErrorCode": "UNKNOWN_ITEM" },
                    { "recordName": "three", "serverErrorCode": "THROTTLED" }
                ]
            }),
            &expected,
        )
        .unwrap();

        assert_eq!(
            accounting.confirmed,
            ["one", "two"]
                .into_iter()
                .map(str::to_string)
                .collect::<HashSet<_>>()
        );
        assert_eq!(accounting.failed, vec!["three (THROTTLED)"]);
    }

    #[test]
    fn modify_response_must_confirm_the_locally_reserved_identity() {
        let expected = format!("{SIGNAL_RECORD_PREFIX}00000000-0000-0000-0000-000000000001");
        assert!(verify_saved_record(
            &json!({ "records": [{ "recordName": expected.clone() }] }),
            &expected
        )
        .is_ok());
        assert!(verify_saved_record(
            &json!({ "records": [{ "recordName": "different" }] }),
            &expected
        )
        .is_err());
    }
}

# Preserve task recovery when secure storage cannot be read

Source repair; execution pending. This follows [saved phone question recovery](PHONE_QUESTION_RECOVERY_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, model invocation, account login or SSH attempt occurred.

Follow-up: [conditional recovery mutation](PHONE_STORAGE_MUTATION_REVIEW.md) binds writes and retirement to the owned record across cooperating app-process store instances, reports deletion failure and conditions reconnect rebinding. Cross-process coordination remains open. Counts below describe this read-recovery checkpoint.

## First-principles findings

A failed lookup is not evidence that no task exists. The previous production Keychain loader grouped a non-successful `SecItemCopyMatching` result with malformed, mismatched and expired records, then called `remove(hostID:localAccountBinding:)`. A temporary read failure could therefore cause deletion of the recovery entry. The same nil return told the session model and local connection coordinator that they could start without a previous task. This threatened pending prompt identity, exact answer bytes, saved questions, control intent and approval recovery.

The new saved-question ownership check also treated an unreadable entry as a replacement by another request. It would abandon the in-memory question and draft, even though storage had supplied no evidence of a replacement. Saving a draft or new request successfully afterward would not prove that overwriting the unread entry was correct.

Finally, the local coordinator read a record before the TLS handshake, then saved that old snapshot under the current pairing code afterward. The handshake suspends. A newer draft or answer, a removed record, or a different session could appear during that interval. Authentication of the Mac does not establish that the old recovery snapshot is still current.

## Source repairs

1. **Distinguish failed reads from successful absence.** The [pending store](../../../ios/RemoteDesktop/ComputerUse/ComputerUsePendingPromptStore.swift) adds throwing `read` and `readForLocalRecovery` methods. Production reports unavailable storage separately from invalid data and an earlier pairing code. `errSecItemNotFound` still means absence. The existing 24-hour age policy still makes an expired record unavailable for automatic recovery. All lookup paths are now read-only: failed, invalid, mismatched and expired reads issue no deletion. The optional `load` wrappers remain for compatibility and also perform no deletion; production recovery callers use the throwing methods.
2. **Exercise the production decisions with an injected Keychain adapter.** The default adapter calls the same Security APIs with the same account namespace, service, synchronization setting and device-only accessibility policy. A deterministic adapter can supply status codes and bytes while observing every mutation. This separates source-level decision coverage from eventual physical-device Keychain qualification.
3. **Block uncertain startup.** The [client model](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) preserves a read error instead of treating it as an empty session. It shields remote pixels and sends no prompt, probe, approval, refresh or control replay from that initial state. New-request actions are refused. Reconnection is required because the unread entry may contain a different session ID; unlocking storage cannot authenticate that session on the already selected channel.
4. **Check before replacing an idle record.** A new request checks storage before saving. An unreadable record prevents submission. An unexpected saved record requires reconnect rather than being overwritten by an idle older model. Successful saving alone is not proof that replacement was permitted.
5. **Keep questions through a read outage.** Draft saving, answer submission, recovery probes and received probe results distinguish a replaced record from a failed read. A failed read retains the waiting question, exact in-memory draft and original deadline. It cancels the current probe correlation and disables answering. **Check again** uses a fresh probe after storage becomes readable; an earlier result cannot enable answers. Starting a new request cannot discard this waiting record while its ownership is unreadable. Confirmed replacement still abandons the older local question without deleting the newer entry.
6. **Re-read after authentication.** The [local connection coordinator](../../../ios/RemoteDesktop/SessionModel.swift) uses the throwing lookup before choosing a session. After handshake and account revalidation it reads again. Read failure stops recovery; a different current session requires reconnect. A same-session record is rebound from its latest snapshot, retaining its latest question or answer. A removed record is not recreated from the pre-handshake snapshot. The existing account/TLS checks remain prerequisites.

## Prepared verification

Seven new methods are authored and unrun. Their exact identifiers are in the [storage-read inventory](phone-storage-read-inventory.json).

Four [client core methods](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) specify:

- Production store handling of multiple Keychain error statuses, corrupt/missing returned data, wrong host/account scope, pairing changes, expiry and true absence, with no lookup mutation and readable recovery afterward.
- Unreadable startup for an executable request and a saved question, no outbound messages, preserved stored bytes, and recovery of the original prompt identity or a read-only question probe through a newly created model.
- Failed reads during draft flush, restart and delivery of a fresh native reply, retaining exact Unicode draft bytes and original clocks and requiring a new probe afterward.
- An idle model refusing to overwrite a task hidden by a failed read or saved by another instance.

Three [connection methods](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift) specify:

- A failed initial recovery read stopping before handshake or visual connection.
- Failed reads and a changed session after handshake stopping before rebinding or constructing an active client.
- Rebinding the latest same-session question draft and retaining its deadline, while a removed record stays removed.

The connection fixtures inject account validation, task channels, storage and visual transports. The proposed cases use no real network or website. They are registered for the full iOS test target and the seven-method source inventory; the standalone client core runner includes only the four platform-independent additions.

Five changed Swift files pass parse-only checks. Exact source registration is **1864 default host / 1181 focused host / 25 focused client core / 7 storage-read methods**. The host counts are unchanged; client core has four additions and no removals. This does not establish type correctness, compiled discovery, passing assertions, successful Keychain access or visible mobile behavior.

## Remaining repair and qualification work

1. Compile and run these cases only after the execution pause is lifted. Inspect actual locked/unlocked-device behavior, account changes, reconnect errors, draft restoration and physical Keychain failures separately.
2. Qualify or add atomic replacement and deletion across independent store users/processes. These synchronous client checks and the post-handshake read close the observed asynchronous gaps; they do not constitute Keychain compare-and-swap. Existing `save` and explicit `remove` operations still have their own concurrency and failure-reporting limits.
3. Provide a deliberate recovery/discard path for an invalid entry without silently claiming that its task never executed. Corrupt entries now remain preserved and block automatic replacement. An unavailable in-memory draft cannot survive process termination unless its write actually succeeded. The 24-hour retention policy and clock changes still need product qualification.
4. Alternate stores retain default adapters to their old optional loaders. They must implement the throwing methods to distinguish their own read failures. The production Keychain store implements them; old optional wrappers must not be used to decide that it is safe to create or overwrite a task.
5. Continue native browser/process/account recovery, semantic corrections, provider controls, result verification and explicit login handback in [the repair tracker](../../../TODO.md). Readable phone storage and a successful question probe do not prove that browsing or authentication succeeded.
6. Keep resource optimization and model qualification deferred. Alternative models and the reported RTX 3080 desktop remain options for later measured failures. No model switch, inference, distillation/pruning, desktop access, 8 GB qualification or real flight/concert/movie test occurred.

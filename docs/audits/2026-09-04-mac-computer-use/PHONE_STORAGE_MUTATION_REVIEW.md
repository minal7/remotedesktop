# Bind phone recovery writes and deletion to the owned record

Source repair; execution pending. This follows the [secure storage read repair](PHONE_STORAGE_READ_RECOVERY_REVIEW.md). No build, typecheck, assertion/test run, application/browser launch, inference, login or SSH attempt occurred.

## First-principles findings

Preventing deletion after a failed read did not establish ownership of later writes. `persistActivePrompt` still saved unconditionally, and `clearActivePrompt` deleted by host/account namespace after dropping its local task identity. An older model could receive a terminal reply, process a status, or persist a control choice after another instance had stored a newer request. The older operation could then overwrite or erase that newer recovery record.

Questions had an ownership read before draft saves and retirement, but the check and mutation were separate operations. Reconnect likewise read the latest snapshot after authentication and then saved it unconditionally. A storage mutation needs one precondition: the record being replaced or deleted is exactly the state this caller owns. A successful read at some earlier point is insufficient.

Deletion also had no result. The client could report a question discarded or a task cleared while Keychain deletion had failed. A later reconnect would find a record the interface had already forgotten.

## Source implementation

1. **Conditional storage operations.** The [pending store](../../../ios/RemoteDesktop/ComputerUse/ComputerUsePendingPromptStore.swift) adds `replace(_:expecting:)` and `remove(ifMatching:)`, with applied, conflict and unavailable results. An expected nil record admits creation only after a successful lookup of absence under the existing retention policy. Replacement cannot move between host/account namespaces; an authenticated pairing-code rebind may retain that namespace. A changed pairing is a conflict. Read errors or invalid records do not authorize mutation.
2. **Compare the complete known recovery state.** Snapshot comparison first checks the complete decoded record, then its deterministic JSON encoding. This preserves distinctions between canonically equivalent Unicode strings in prompt bodies, questions, drafts, approval data and other encoded text. Comparing a task ID or Swift's canonical string equality alone is insufficient. Existing records and exact transmitted prompt bodies keep their format.
3. **Serialize cooperating store instances in this process.** A shared recursive mutex encloses conditional lookup and mutation. Production reads, unconditional compatibility saves and explicit namespace removals also participate, including instances with separate store objects. The Keychain adapter and namespace/accessibility policy remain unchanged. This is an app-process boundary, not an atomic Keychain transaction against other processes or older app versions.
4. **Retain the active client's last saved snapshot.** The [client model](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) tracks the exact record restored or successfully saved. Prompt creation, answers, control/approval persistence, host-state updates and conversion into a saved question replace that snapshot conditionally. A successful write advances the owned snapshot. Failed writes do not advance it. Terminal clearing conditionally deletes the prior snapshot before dropping local ownership, so an obsolete reply cannot delete a newer request.
5. **Use conditional question writes and retirement.** Draft updates, freshly verified question restoration and new-request transitions use the same store precondition. A failed question deletion retains the local recovery record and reports failure; the user can retry the explicit new-request action when storage is available. Expiry still disables answering while unsuccessful retirement retains the recoverable entry. A confirmed conflicting record remains untouched.
6. **Stop stale outbound work.** Ownership conflict requires reconnect, shields remote pixels and cancels pending refresh, control, probe and outbound tasks. Queued operations check their task/state generation and active stored snapshot before channel handoff. A read failure at that boundary also prevents transmission. This cannot recall a send already handed to a transport; native control ordering and prompt idempotency remain necessary.
7. **Keep unsuccessful terminal cleanup visible.** A confirmed task result remains the task result, but failed recovery deletion blocks a new request and asks for reconnect. Reconnect reuses the original task ID/body so the host can replay its durable result without inventing another execution. The phone does not pretend that unsuccessful deletion erased its record.
8. **Condition the authenticated rebind.** The [connection coordinator](../../../ios/RemoteDesktop/SessionModel.swift) now replaces the post-handshake snapshot conditionally. A change after its final lookup stops connection completion rather than overwriting the newly stored record. Account validation and the exact authenticated session remain prerequisites.

Apple documents separate item queries and mutations, including matching attributes for updates and status checking for failures. Those API descriptions support the existing adapter calls; they do not establish the cross-process transaction semantics of this patch. The process-wide serialization described here is our implementation choice. See [Apple's update API](https://developer.apple.com/documentation/security/secitemupdate(_:_:)) and [updating and deleting Keychain items](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items).

## Prepared verification

Six new methods are authored and unrun, selected by the [mutation inventory](phone-storage-mutation-inventory.json).

Five [client core methods](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) specify:

- Two production store instances competing to replace one snapshot, exactly one winner, stale replacement/deletion refused, and canonically equivalent but byte-distinct text kept separate.
- Read, update and delete errors preserving the owned bytes, and an older pairing unable to mutate the rebound record.
- Older active clients unable to overwrite or delete a newer task through terminal/question replies, Pause, Resume, approval decisions or prompt refresh.
- Failed question retirement retaining the original reference until an explicit retry succeeds.
- Failed terminal retirement preserving the confirmed outcome and replaying the original request identity after reconnect before another request can be created.

One [connection method](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift) changes the saved record between the coordinator's last lookup and conditional rebind. The proposed assertion requires the newer record to survive with no write or active client creation. The fixture uses injected storage, account validation and transport; it does not connect to a website.

Five changed Swift files pass parse-only checks. Exact source registration is **1864 default host / 1181 focused host / 30 focused client core / 6 mutation methods**. The preceding seven-method storage-read inventory still matches its selected source methods. Five client core methods were added, with no removals. Syntax and source registration do not establish type correctness, compiled discovery, passing assertions or actual Keychain/UI behavior.

## Remaining repair and qualification

1. When execution is authorized again, compile and run the mutation, read-recovery, control/approval, question and composition cases. Check actual failed deletion, lifecycle transitions and reconnect messages on iPhone/iPad. No assertions or platform UI were executed here.
2. Add or qualify cross-process coordination deliberately if independent processes or older writers can share this store. The mutex protects cooperating instances of this app process. It does not constrain outside writers, and the read/mutation pair is not advertised as system-wide compare-and-swap. Alternative stores must also honor the protocol's mutation contract; their raw compatibility methods do not automatically acquire this process mutex.
3. Qualify serialization cost and main-thread Keychain access when resource work resumes. The process lock and exact encoding are correctness measures, not evidence of acceptable latency or 8 GB behavior. Native APIs can block; actual contention, background access and cancellation need measurement.
4. Complete deliberate handling of corrupt records, retention/clock policy and termination during a failed draft write. Preserving unreadable or unremovable state is not a substitute for a usable recovery path. Native browser/account/process ownership and action receipts still require their own recovery design.
5. Continue semantic interpretation/corrections, provider controls, whole-goal result verification and login handback in [the repair tracker](../../../TODO.md). Alternative models and the reported RTX 3080 machine remain deferred options; no model, thermal or real travel/concert/movie qualification occurred.

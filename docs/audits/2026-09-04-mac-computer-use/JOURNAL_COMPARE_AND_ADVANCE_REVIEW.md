# Preserve step progress across competing journal writers

Parent source: `d6958ea`. Status: source repair and regression registration only. No build, XCTest execution, inference, app launch, computer-use activity or installed-app replacement ran. Performance work and live travel/concert/movie acceptance remain deferred.

## First-principles defect

An atomic file replacement prevents readers from seeing half-written JSON. It does not prove that the replacing writer still owns the latest state.

`ComputerUseTaskJournalStore.save` previously replaced a task journal without checking its current contents. Each `ComputerUseTaskExecution` prevents concurrent `run` calls on that instance, but a second instance or process can load the same earlier journal. Both could then save an attempted step and reach their effect adapters. A stale instance could also replace newer verified progress with its older attempted or uncertain state. Serializing only the rename would still permit this lost update.

The required boundary is one operation that checks the expected previous journal and commits an allowed successor while excluding other cooperating writers. The next effect must remain downstream of that successful commit.

## Source repair

- `save` now requires `replacing:` with the last journal the caller actually loaded or successfully committed. `nil` means the caller observed no journal. Under one exclusive lock, the store reads the current record, compares its full identity and statuses to that expectation, and only then writes a successor. A conflicting writer receives `staleJournal`; its expectation is not refreshed automatically.
- Native form execution and owned-browser navigation each retain that expected journal in their persistence closure. They advance it only after the store confirms success. Their existing transaction engine still records `attempted` before calling an effect adapter, and errors do not authorize fallback to desktop execution.
- The store enforces a verified prefix, at most one attempted/uncertain step and a planned suffix. A new file can contain all planned steps or the first attempted step. Later writes can advance one planned step to attempted, reconcile attempted to verified/uncertain, or reconcile uncertain to verified. Identical state is permitted when it is also the expected current state. Rewinding, skipping an attempt, changing the contract or modifying multiple steps at once is rejected.
- Task and step identities are compared as exact UTF-8. Prompt and contract digests must be lowercase SHA-256 strings. Invalid identities, duplicate steps, impossible histories and mismatched status counts fail during load and save instead of becoming new work.
- Each task uses a stable owner-only `.lock` sibling. The lock is separate from the JSON inode because the JSON is replaced by rename. Reads use a shared lock; compare/write uses an exclusive lock. Both use nonblocking admission. A per-instance lock also rejects concurrent or reentrant calls without waiting. Lock files are retained rather than unlinked on release.
- Both journal and lock files must be ordinary files with the expected owner, permissions and one link. Symlink, hard-link, directory, FIFO and unsafe-permission cases are rejected. Journal opens now include `O_NONBLOCK`, allowing the type check to reject a FIFO without hanging first. A lock-file inode check after acquisition detects replacement during admission. The existing read-only existence probe still creates nothing and treats malformed journal entries as present.
- Once a write starts, a failure leaves that store unavailable. In particular, rename can succeed before the directory flush fails. The old in-memory expectation must not authorize another write after that ambiguity. A newly constructed store can inspect the state that survived; attempted work still requires independent effect evidence and is never automatically replayed. The writer's `FileHandle` is explicitly retained until after synchronization.
- Errors now describe the inability to use saved progress without asserting that no previous action happened or promising an automatic retry.

The locking choice follows [Apple's `flock(2)` documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html): the lock coordinates cooperating processes, and nonblocking admission reports contention immediately. The current SDK manual and the repository's installer already use the same mechanism. The Swift C-symbol alias follows the installer to avoid Darwin's struct/function name collision. These sources support the mechanism, not runtime qualification of this patch.

## Prepared regressions

Six new store methods cover:

1. Two stores that observed an absent journal; a stale initial attempt cannot overwrite the winner. A stale uncertainty update cannot replace verified progress, while a caller using the actual current state can finish the remaining step.
2. First-write completion/uncertainty rejection, attempted-to-planned rewind, skipped transitions, changed prompt/contract/Unicode step identity, and allowed uncertainty reconciliation.
3. A second store attempting to read or save while the first holds the lock across rename. It must receive `busy`; an unrelated task remains accessible. The sibling lock inode must remain stable across replacements, and a stale expectation remains stale after contention ends.
4. Failure immediately after replacement. The visible attempted record is retained, temporary files are cleaned up, and the original writer cannot resume after its injected failure disappears.
5. Ten unsafe-file cases across journal and lock paths: symlink, hard link, directory, permissions and FIFO. Protected fixture contents remain unchanged.
6. Invalid digests, duplicate step IDs, mismatched status counts and impossible histories. Neither load nor a fresh save can erase the invalid existing record.

Two new shared-engine methods compose the real store with controlled effect adapters:

7. Two executors constructed from the same absent snapshot. After the first finishes all four typing/submission steps, the stale executor cannot dispatch anything, replace completion or refresh itself on another run.
8. Failure after the attempted write and after the verified write. An unconfirmed attempted write dispatches nothing and cannot acquire retry authority merely because the file is visible. If the effect was already delivered and its verified record survives, reconstruction continues the remaining steps without repeating it. These fixtures distinguish actual captured effects from saved status.

Existing store fixtures now supply the expected prior state and valid digests. Corrupt/symlink cases also reject writes. No journal format fields were added, and all changed Swift files were already registered in the project.

## Verification and remaining work

The source inventories match **545 default** and **68 focused** identifiers; `git diff --check` passes. See [the focused inventory](journal-compare-and-advance-inventory.json). No compiler or test method ran. The optional post-replacement callback is a controlled fault seam; it does not simulate actual power loss or prove filesystem crash behavior.

1. When execution is authorized, compile and run the focused cases, then qualify real independent processes, lock contention, cancellation, filesystem failures and restart through the native/browser adapters. Measure lock/write cost in the deferred performance phase.
2. This lock covers journal access, not the full lifetime of an asynchronous effect. Cross-process executor ownership, old binaries that do not cooperate with this lock, routing across different capability stores, and reconstruction while another adapter is still acting remain separate work. Arbitrary same-user writers can ignore an advisory lock. Do not claim general exactly-once execution from this change.
3. The host prompt ledger and MCP records have their own persistence mechanisms; they do not inherit this store's locking or synchronization. Unify their ownership and recovery guarantees deliberately. Retained lock files also need lifecycle rules that never split a live lock.
4. Continue durable native/visual effect receipts and whole visual/structured task contracts with stable steps, future entities, repeated TYPE/Return, search/submission outcomes and independent completion checks. This patch does not qualify browser ticket searches, actual phone transport, 8 GB memory use or thermal behavior.

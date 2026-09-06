# Keep one owner through a task run's actual return

Parent source: `a30215a`. Status: source repair and regression registration only. No build, XCTest execution, inference, app launch, computer-use activity or installed-app replacement ran. Performance optimization and live travel/concert/movie acceptance remain deferred.

## First-principles gap

The journal's compare-and-advance write protects saved progress from stale replacement. That alone does not protect the time between writes.

An action can still be running after its `attempted` state is saved. A second executor may load that state and begin observing postconditions while the original adapter is still acting. If visible conditions already match, the second executor could mark the action verified and begin a later step before the original call returns. The instance-local `isExecuting` flag excludes a second call on the same object, but not a reconstructed object or another cooperating process.

Cancellation is not proof that the adapter has returned. Releasing ownership in a cancellation handler would reopen exactly this race. Ownership must cover the actual calls, their verification and their unwind.

## Source repair

- Added a small `ComputerUseTaskExecutionLease` interface to the shared transaction engine. At the start of each `run`, the engine checks cancellation/ownership and acquires its configured lease before any transaction observation or effect. It checks the lease at the existing observation/action ownership boundaries, including after adapter returns and before accepting the final outcome.
- Release occurs in the run's exit cleanup. No cancellation handler releases the lease early. A stalled awaited call continues to exclude a duplicate run until it returns. Success, thrown observation errors, failed writes and cancellation all release ownership when the run actually exits.
- `ComputerUseTaskJournalStore.acquireExecution` takes a nonblocking exclusive lock on the task's stable `.execution.lock` sibling. Under that ownership it compares the current journal to the caller's expected state using the existing journal lock. A stale or invalid snapshot fails admission; it is not silently refreshed. Failed admission releases its acquired descriptor.
- The lease retains its directory owner and lock descriptor. Validation checks that the descriptor remains an owner-only regular file with one link and that the path still names the same inode. Release is idempotent; deinitialization is a final cleanup path. Stable execution lock files are retained, just like the journal lock siblings.
- Journal reads remain available during a run for inspection. Writes from another store also respect execution ownership: a standalone writer must acquire the execution lock before the journal lock. The owning store can use its active lease for writes. Weak ownership references avoid a store/lease retention cycle. A duplicate writer cannot change the owner's progress merely by bypassing the shared engine.
- Native form tasks pass the lease provider through `ComputerUseTextTask` to the engine. Owned-browser navigation supplies the same provider directly. Each uses its last successfully persisted journal for admission. Replaying a retained completed task reacquires ownership and still checks fresh final predicates.
- Controlled in-memory engine fixtures can omit a lease provider. The two production users of this journal-backed engine supply one. New capability integrations must do the same; an optional fixture seam is not permission to omit production ownership.

The stable advisory-lock mechanism and its platform basis are described in the [preceding journal review](JOURNAL_COMPARE_AND_ADVANCE_REVIEW.md). This change extends the lock lifetime through a run; it does not change model configuration or implement performance tuning.

## Prepared regressions

Seven new methods cover:

1. Duplicate execution admission before and after an attempted journal is written, blocked writes from a second store, readable progress during the run, independent task IDs, idempotent release and stale admission after release.
2. Failed admission against a corrupt journal, subsequent recovery of the correct record, and lease deinitialization releasing ownership.
3. Unsafe execution-lock symlinks, hard links, directories and FIFOs, plus permission and path changes to a live lease. Protected fixture contents are retained.
4. A shared-engine run suspended in initial observation, its first effect, postcondition observation or final outcome verification. A reconstructed executor attempts to run before and after Stop. It must reach neither observation nor effect while the original remains suspended. After the original actually returns with cancellation, a fresh reconstruction completes the remaining work with exactly four distinct effects and two submissions; no delivered step repeats.
5. Successful execution, an observation failure and a failed durable write. Another owner can acquire after the run exits in each case.
6. Execution-lock replacement during observation, an effect or final verification. A matching application value cannot authorize more input or task completion after ownership is lost.
7. The text-task adapter forwards admission before its first field read. Once the former owner releases, the task can run and then replay without another edit; both runs reacquire and release ownership.

Two existing shared-engine/store regressions now also acquire execution leases: stale fresh-snapshot writers and failures after attempted/verified replacement. The controlled search fixture gained a suspension hook after an effect and a reusable observation method. Its existing exact effect and submission assertions remain. No fixture uses a model or sends real input.

## Verification and remaining work

Source inventories match **552 default** and **75 focused** identifiers; `git diff --check` passes. See [the focused inventory](task-execution-lease-inventory.json). All changed Swift files were already registered in the project. These are source checks, not compilation or execution evidence.

1. When execution is authorized, compile and run the focused cases, then qualify actual independent processes, cancellation, repeated resume and restart through native and browser adapters. Verify descriptor cleanup and contention on supported macOS/filesystems. No process or UI qualification occurred here.
2. The lease is per task and journal directory. It does not establish one global owner of the Mac across different task IDs, native/browser store directories, visual control, MCP or old binaries that do not cooperate. Global controller ownership and the other durable stores remain open.
3. Admission begins at the shared transaction's `run`. Discovery, planning and contract construction that precede that call are outside this lease. Their existing cancellation/ownership checks remain; this patch does not provide global planning admission.
4. A lease lasts until the adapter call actually returns. If an adapter returns before an OS operation or callback has finished, that outstanding operation still needs its own retained ownership and reconciliation. Existing native application-open and browser navigation protections remain separate; audit every early-return boundary. A deadline must not grant retry authority for an operation that may still be acting.
5. This coordinates cooperating writers. Arbitrary same-user code can ignore advisory locks or replace files. The inode checks detect replacement at checked boundaries; they do not make an arbitrary desktop effect atomic.
6. Continue complete visual/structured task contracts, future entity bindings, per-step TYPE/Return authority, native/visual effect receipts and independent compound-goal verification. Real travel, concert and movie searches remain unqualified. Measure added ownership checks and descriptor/lock lifecycle during the deferred 8 GB and thermal performance phase.

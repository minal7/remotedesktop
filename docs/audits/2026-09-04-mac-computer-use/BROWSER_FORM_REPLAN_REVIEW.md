# Retiring stale form plans before input

Source checkpoint after `e3b0063`. Runtime qualification remains paused. The [working repair list](../../../TODO.md) remains open.

## First-principles failure

A prepared form plan is a proposal about a particular observed state. If the website changes that state before input, the app should plan again. It must not confuse that case with a partly completed or uncertain action. Previously, accepting a form stage made it pending even when its first preflight failed before any input or journal write. Resume retried the same immutable stale plan indefinitely, and that pending stage blocked new planning and clarification.

Dropping the stage would lose two boundaries. First, a failed disk or callback return does not prove no input happened. Second, an old runner must not execute a plan after another runner replaced it. A new stage also needs a distinct identity even when it occupies the same logical position after the last completed stage. The repair therefore separates native no-attempt proof and revocation, durable retirement, and new planning. It keeps historical completed work independent of a discarded proposal.

## Source implementation

1. **Durable retirement marker.** [The journal](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskExecution.swift) has an optional `retirementDigest`; legacy records without it still decode with no retirement. A marker is valid only for an all-planned journal. [The store](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextStepStore.swift) has a separate `retireUnattempted` operation requiring the caller's active execution lease, exact journal identity, all-planned statuses and an exact compare-and-swap. Ordinary save and unattempted binding replacement cannot create, change or clear retirement. Journal comparisons include the marker. A fresh idempotent retirement also syncs the directory to resolve a prior visible-but-unconfirmed rename.
2. **Retired plans cannot recover as runnable work.** Both the generic transaction engine and [text compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextTask.swift) reject a recovered retired journal. Text journal projection retains the marker. The compiler exposes its actual input operation IDs without running any observation, persistence or effect callback; retirement uses these same IDs rather than a second identity formula.
3. **Prove absence in the original native ledger.** [The isolated browser dispatcher](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now identifies each input ledger. Discovery and document-root reset change that identity whenever they clear the ledger. The original adapter retains it, including through an authorized clarification transfer. `retireUnsentInputs` accepts only that exact document/ledger and one to eight original operation IDs with no native attempted/dispatched entries. In one synchronous operation it revokes all those IDs. A later input with a revoked ID is rejected. Repeating the same retirement is idempotent. A replacement ledger cannot turn missing entries into no-attempt evidence. Retired IDs have a separate bounded set of at most 512 entries and do not erase earlier dispatched receipts.
4. **Retain retirement through ambiguous returns.** [The form stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) holds its execution lease from the loaded journal through native revocation, durable retirement and cancellation unwind. It declines retirement after observing any attempted/uncertain/verified journal state or entering its native apply boundary. Once revocation begins, ordinary Resume cannot run the old plan; only retirement resolution can proceed. A failed write retains the same original plan and native IDs for a fresh leased retry. Native reads are joined before releasing the stage. A committed retirement remains a historical fact after Pause closes its outer return.
5. **Preserve completed work and allocate new authority.** [The research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) separately retains the latest completed stage and a typed retired-form history. After confirmed retirement, it restores that completed stage's original adapter and continuation. Confirmed form receipts remain unchanged. A separate sequence counts accepted attempts, so the version-2 stage ID includes both logical completion index and attempt sequence. Replanning cannot reuse the retired stage namespace. Existing thirty-two completed-stage and sixty-four input-receipt bounds remain; at most sixty-four stage attempts may be accepted by the retained owner.
6. **Continue the default driver.** [The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) handles stale form/page/precondition failures and unfinished retirement by asking the owner to retire only proven no-attempt work. Success returns to the complete-goal action/form planners. It neither replans an attempted/uncertain stage nor turns an arbitrary storage, authentication or model failure into retirement. Pending initial and dependent form stages use this path. Earlier search/navigation/input history is retained.

No model prompt, model package, runtime worker or installed app changed. The parent research graph is still process-local; this checkpoint does not reconstruct a task after browser or host loss. The durable marker prevents revival of the particular retired child journal, but is not a substitute for the remaining parent recovery work.

## Prepared coverage — not executed

Nine methods in [the replanning tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormReplanTests.swift) specify:

- Default-driver replanning after value drift and native-object replacement before the first edit, covering both an absent journal and a saved all-planned journal, distinct stage authority and no repeated search.
- Retirement of an unsent dependent stage while preserving the completed category, outside preservation and original input receipt.
- Refusal to retire attempted or verified journal states after an ambiguous write.
- Fresh leased retirement resolution after a failed post-rename write, with old execution blocked meanwhile. An exact saved marker records positive earlier proof and can finish its directory sync even after a ledger reset; a missing marker still requires the original native ledger.
- Pause during native revocation, joined completion and explicit handback before continuation.
- Rejection of a reset native ledger as evidence of no earlier input.
- Refusal to revive the tombstone through normal save, binding replacement or text-task recovery; retirement itself requires an execution lease.
- Exclusion of a second execution owner before native revocation.
- Adoption of a retirement committed just before Pause, with no duplicate retirement history or input.

These fixtures use controlled planner choices. They do not verify model understanding, native runtime behavior or complete research results. No held-out data was inspected or used.

## Remaining repairs

1. **Reconcile attempted and partly completed stages.** An attempted journal with independent proof of no native input, a verified prefix with a changed remaining suffix, resets during effects and partial document loss need explicit per-step recovery. This checkpoint intentionally requires an all-planned journal and does not discard uncertain history.
2. **Reconcile replaced required objects after input.** Replacement of an unexecuted target can now lead to fresh planning. A field required by an earlier completed stage still needs a source-bound mapping to a new native object while preserving the old receipt. Equal labels or values cannot supply the missing identity.
3. **Revise obsolete criteria and revoked preservation.** The current continuation still requires retained criteria unless an explicit edit supersedes its field. Releasing a submission requirement or preservation instruction needs a representation grounded in the updated user request.
4. **Complete document/login and parent recovery.** Finish provider-window and host/phone handback after lost native authority, preservation across pages, durable original-goal/step recovery, archived evidence and cleanup. A lost ledger cannot be repaired by claiming its old operations were unsent.
5. **Complete and qualify browsing/results.** Broader date/location/party semantics, custom widgets, POST/dynamic/embedded submissions, offer association, availability, fees, distinct result counts, ranking, public source links and full answers remain open. Later qualification must include the retained travel, concert and movie website tasks.
6. **Respect the current execution pause.** Typechecking, builds, bounded native/model qualification and real-site E2E await authorization. Keep the 8 GB Mac target; performance optimization follows correctness repairs. Alternative models and RTX 3080 adaptation remain authorized, with SSH connectivity unresolved.

## Source verification

Eight changed Swift files passed syntax parsing only. Four JavaScript syntax checks covered the fixed production dispatcher and three fixture script variants. The Xcode project property list and new source registration were checked. The default and [focused inventories](browser-form-replan-inventory.json) match 1040 and 357 method identifiers. Local documentation links and whitespace were checked.

No typechecking, builds, test/assertion execution, inference, app launch, computer use, remote training or real-site E2E ran. Source checks do not establish working natural-language behavior or close the overall goal.

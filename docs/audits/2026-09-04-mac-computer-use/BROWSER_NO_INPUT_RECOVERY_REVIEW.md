# Recovering disk attempts that never reached native input

Source checkpoint after `4a6bb61`. Runtime qualification is paused and the [working repair list](../../../TODO.md) remains open.

## First-principles distinction

The disk journal records intent before an input call. Its `attempted` state must therefore mean that input may have happened, not that it necessarily happened. A write can fail after rename, or Pause can arrive after that write and before the native call. Resume can then mark the step `uncertain` because neither a matching value nor a native dispatch receipt proves success.

The previous retirement path rejected every attempted/uncertain disk state. That stranded work even when the original browser ledger could prove that no native input began. The important boundary is the native ledger: its dispatcher inserts an attempt before the setter, selection change or input event. It never evicts individual attempts. Clearing that ledger changes its identity. An absent operation is meaningful only in that original ledger, after the earlier call has finished, while another runner is excluded.

The repair uses that stronger proof without rewriting history. An old disk attempt remains recorded as attempted or uncertain, but its plan may be retired after its original native IDs are atomically revoked as unsent. A new proposal receives distinct stage authority. Any native attempt, a lost ledger without an exact previously saved retirement marker, or a verified prefix continues to block whole-stage retirement.

## Source changes

1. **Do not treat the Swift call boundary as native input.** [The form stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) no longer permanently rejects retirement merely because it loaded an attempted journal or entered its Swift apply closure. It caches a native attempt only when the original dispatcher reports an existing entry for one of the compiled operation IDs. The unchanged native dispatcher records that entry before any value, selection or event effect.
2. **Retain attempted/uncertain statuses.** The stage's `retireUnsent` method loads the exact journal under the original execution lease. It refuses any verified step, retains every existing status, and sends every compiled operation ID to the original native ledger. The already implemented synchronous revocation remains mandatory unless an exact saved retirement marker records the earlier proof. No step is reset to planned; no old operation ID is retried.
3. **Store the stronger retirement without reviving execution.** [The store](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextStepStore.swift) now names its operation `retireUnsent`. A retired journal may retain the valid first attempted/uncertain step and planned suffix, but cannot contain a verified step. Existing sequence validation, exact statuses in compare-and-swap, the active execution lease, atomic write, directory sync and failed-write handling remain. Ordinary save/binding replacement still cannot create or clear retirement, and text/generic execution still rejects a retired journal.
4. **Continue recovery through the default driver.** [The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) now requests no-input reconciliation for uncertain effects, incomplete outcomes and uncertain delivery as well as stale input. The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) adopts only a successful retirement receipt. Failure to prove no native input leaves the pending stage intact and returns the existing reconciliation outcome. Storage failures, ownership changes and authentication do not become permission to replan.
5. **Keep the preceding guarantees.** A failed retirement write blocks old execution and resolves through a fresh leased load. An exact saved marker records positive earlier proof even if its ledger later resets. The latest completed form, original task, accepted answers and historical receipts remain retained. Replanning uses the existing distinct attempt sequence and bounded stage/input counts. Model context, prompts, workers and installed app were not changed.

The positive and negative cases are intentionally different: a native `attempted` entry blocks retirement even if the page restores the old value or replaces the field before the callback completes. An absent entry in a replacement ledger proves nothing. Equal current values cannot supply an input receipt.

## Prepared coverage — not executed

Eight new methods in [the no-input recovery tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserNoInputRecoveryTests.swift) specify:

- Default-driver recovery after a failed attempt write, preserving the resulting uncertain disk history and issuing one new category/city input sequence under a distinct stage without repeating the original search.
- Direct retirement of an attempted disk state while preserving its exact statuses, step IDs, prompt and contract identity.
- Pause after the disk attempt but before native input, with explicit handback before proof and replanning.
- Refusal after native input whose callback/final value becomes uncertain, both when the field is replaced and when the site restores the old selection.
- Preservation of a verified prefix when the second disk attempt was saved but not dispatched.
- Refusal to infer no input after the original ledger was replaced.
- Matching values supplied by the page remaining insufficient as receipts, followed by a new plan only after original-ledger absence proof.
- Recovery after a failed attempted-state retirement write, with statuses retained and no repeated native revocation or old input.

The earlier replanning test now retains its verified-prefix rejection case; its blanket refusal of a disk-only attempt is superseded by these native-proof cases. Positive query fixtures wait for independently observed page input requests before navigation can cancel those requests. Controlled planner responses are not model qualification. No held-out data was used.

## Remaining repairs

1. **Reconcile a verified prefix and remaining suffix.** Preserve completed native receipts and active criteria, revoke only suffix operations proven unsent, and plan justified remaining work. A step whose native input began but lacks a completed receipt needs outcome reconciliation, not a fresh operation ID. Whole-stage retirement must not erase partial work.
2. **Map replaced required objects after completed input.** Retain the historical object/receipt and bind the remaining user requirement explicitly to a newly observed object. Changed labels, constraints and form membership need deliberate handling.
3. **Revise obsolete criteria and revoked preservation.** Source-bound changes under the complete current request must explicitly release or replace requirements; omission is not evidence that a criterion no longer matters.
4. **Finish browser/session and parent recovery.** Document/login transitions, provider windows, host/phone handback after lost authority, preservation across pages, durable original-goal/action state, archived evidence and cleanup remain open.
5. **Finish and qualify research capabilities.** Broader dates/locations/party semantics, custom widgets and submissions, offer association, availability, fees, distinct results, ranking, source links and complete answers remain incomplete or unqualified. Real travel/concert/movie scenarios await later explicit permission. Keep the 8 GB Mac target; performance work follows correctness repairs. Alternative models and RTX 3080 adaptation remain authorized, with SSH access unresolved.

## Source verification

Six changed Swift files passed syntax parsing only. Four new fixture JavaScript variants passed syntax checks; production JavaScript did not change. The Xcode project property list and source registration were checked. The default and [focused inventories](browser-no-input-recovery-inventory.json) match 1048 and 365 method identifiers. Documentation links and whitespace were checked.

No typechecking, builds, test/assertion execution, inference, app launch, computer use, remote training or real-site E2E ran. These source checks do not establish working natural-language behavior or complete the product goal.

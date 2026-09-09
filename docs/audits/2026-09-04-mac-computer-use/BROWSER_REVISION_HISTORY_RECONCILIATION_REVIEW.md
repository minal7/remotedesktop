# Reconcile a failed callback with its exact native revision history

Source checkpoint: 2026-09-09. Parent: `2ed98ff`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A terminal callback error describes the host's delivery result. It does not establish whether the native adapter completed the field revision. The adapter may hold a complete historical catalogue, or a definitive pre-capture rejection, while the host capture holds an error. Repeating the revision would risk replacing its original observation; indefinitely ignoring an available native result would prevent legitimate continuation.

Recovery must ask what the exact original attempt retained. It must not infer success from matching current values or use a new capture to stand in for missing history. Historical fields are also not current input preconditions: changed values still need normal binding and fresh review.

## Native history inspection

[The native adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now stores a canonical representation of the complete revision request beside its bounded one-use record. Only the top-level page snapshot nonce is excluded. Native document ID, scope, selected and preserved controls, private field requirements, earlier origins, repair masks and any additional arguments stay exact. Existing revision retries also require this complete request match.

The new `inspectPreparedRevision` command runs behind the normal authentication, ready-document and current page-projection checks. It requires the original request, the retained result's native document and ledger, the same active catalogue scope and exact binding map, and current preservation. It returns only a recorded successful catalogue or explicit pre-capture rejection, labeled with `recoveredRevisionID`.

Inspection never calls catalogue extension or field `snapshot()`, replaces IDs, dispatches input, creates a state proof or clears history. Its normal page and preservation checks still observe their authorized current surfaces. A changed field value can therefore leave a historical catalogue recoverable, while fresh binding later rejects its use as a current input snapshot. A superseding catalogue, missing record, lost identity, changed preservation or a partial/failed native record cannot supply a replacement result.

## Host reconciliation

[The private capture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) permits reconciliation only for an already started revision with a terminal callback error. Pending calls, successful replies, ordinary returned failure statuses, and the separate empty-authentication path cannot be overwritten. It validates the original arguments before any native inspection, and validates them again before retaining the historical reply. The original error, started flag, revision identity and argument digest remain stored; the recovered reply is separate and accepted once.

[Reply decoding](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) confines the recovery marker to the inspection command. It checks native ledger and revision-ID formats, the expected historical status and field payload, and rejects unrelated page, proof, binding, popup and selection data. A recovered pre-capture rejection must carry matching original and recovered revision IDs.

The target attempts inspection before reusing an errored revision capture. A successful historical catalogue passes the usual discovered-field checks and later fresh binding; it is not returned directly to a model or counted as an effect. Reconciled absence enters the existing ancestor recovery path. [Preparation recovery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) can recognize that result in the same recovery operation and require fresh review without retrying the rejected revision. Owner, cancellation, source-document and preceding-continuation checks still apply.

Cancellation during inspection retains the original failed capture. A later permitted attempt can inspect the same immutable native history again; no new field catalogue is captured. A pending original callback still has to finish or its browser must be released under the existing lifecycle rules.

## Prepared coverage and allowed checks

Nine methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). All are authored and unrun:

1. Reject malformed historical replies, missing/mismatched IDs, unrelated commands and mixed payloads.
2. Retain the original failed attempt while accepting one exact historical result; prevent changed arguments and repeated adoption.
3. Refuse reconciliation of unstarted, pending, successful-status and authentication captures.
4. Recover actual native field history with and without subsequent value changes; return the old snapshot and require fresh binding.
5. Reconcile a retained pre-capture rejection without reissuing the revision.
6. Refuse missing, superseded and unpreserved native history.
7. Require the entire original request, including scope, selection, private requirements and unexpected arguments.
8. Keep a partial native capture failure held after its oversized field becomes readable again.
9. Preserve the failed capture across cancellation of its historical inspection, then inspect the same record again.

The native-history fixtures execute the real revision adapter in their authored scenario, deliberately withhold its reply from a host capture, and inject a terminal callback error. This isolates the delivery boundary; it is not evidence from an actual WebKit delivery failure or from the complete driver/manager stack.

Five changed Swift files passed `swiftc -frontend -parse`. The assembled DOM, five embedded fragments and 59 distinct fixture scripts passed `node --check`. Source inventories select 1589 default / 906 focused methods: nine additions each, with no removed or renamed identifiers. These checks establish syntax and reviewed source identifiers only. Compilation, assertions and real browsing remain unverified.

## Remaining repair order

- Partial native catalogue failures, missing/invalid native history and an original callback still running cannot be reconciled as a completed capture. Any broader recovery must retain the actual observations and task obligations; unsupported fields need honest handling.
- Continue explicit goal supersession and conflicting-answer resolution, including justified changes to earlier invariant, preservation and read duties. The subsequent [clarification-policy checkpoint](BROWSER_CLARIFICATION_POLICY_HISTORY_REVIEW.md) retains the missing prior interpretation and protects concrete source restrictions; actual replacement remains open.
- Complete login document transitions, process/account recovery, required-object replacement and dependent-control reconciliation without rewriting prior effects.
- Continue independent result verification and the full [repair checklist](../../../TODO.md). Real travel/concert/movie tasks, alternate-model comparisons, desktop adaptation and the 8 GB resource target remain unqualified. No assertions, app/browser execution, inference, SSH retry, push or installed-app replacement occurred here.

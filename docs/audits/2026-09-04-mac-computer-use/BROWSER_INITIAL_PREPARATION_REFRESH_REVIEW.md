# Refresh the first form without inventing earlier history

Source checkpoint: 2026-09-09. Parent: `7fc6a4e`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

The first prepared form has the same stale-precondition problem as a later form: a field may change after capture or while its proposed edit is being planned. The old proposal must remain unusable, but the original task can still justify a new scope and a fresh snapshot of the same editable object.

The preceding refresh implementation required a prior continuation so it could check native history. That left initial preparation without a recovery path. Creating an empty preceding stage would misrepresent the task. Simply trusting a nil continuation would be insufficient: native input or proof records can exist independently of the host's optional reference.

The native adapter must establish the absence of input/proof history in its actual current ledger. This is a read-only fact about that adapter, not a criterion proof, a completed form stage or evidence that no other task work occurred.

## Source repair

[The sealed scope review](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserEffectControlReview.swift) now admits initial preparation recovery when the same reviewed form/document has explicit edit intentions and no retain intentions. Existing later-form eligibility still requires its complete preceding continuation. Neither branch grants input authority.

[Preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) can retain a complete or interrupted capture with no predecessor. Its structural validation still requires the original scope, captured field catalogue, preservation, page and baseline. It records only changed new edit preconditions; the set of changed earlier criteria must be empty when no preceding continuation exists. Preservation, scoped reads, metadata and object identity retain their existing restrictions.

If the initial field capture has not started, recovery uses its first real observation. A value differing from an imagined earlier state is not a recorded change. An unchanged capture reports no refresh and can resume ordinary preparation; its native history is still inspected. Started callbacks remain owned and are reused rather than discarded.

[The adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now performs an explicit empty-history inspection before and after initial binding. The request uses a distinct `empty-preparation-history-v1` shape and binds the exact document, native ledger and preservation. Native code requires a nonempty retained field binding set and zero input operations, pending changes, retired inputs and form-state proofs. It returns an empty-history status with no field values or criterion claims. The host checks the returned document/ledger identities and empty changed-ID list.

The existing requirement-inspection command carries this read-only shape; it does not become a query requirement. A missing or reset ledger, a prior input attempt, or an existing observation proof cannot be replaced by a host assertion that history is empty. Cancellation checks surround the native boundaries, and the recovery record is published only after the final current-owner checks.

## Native revision and continuation

Initial refresh uses `refreshable-initial-form-v1`, distinct from later refresh backed by earlier criteria. Native revision rejects supplied earlier origins and retention mode, requires empty operation IDs and no repairable earlier-criterion IDs, and repeats the empty-history check at the actual capture boundary. Refreshed IDs must belong to submitted captured fields and be explicitly selected in the new revision. Fields outside that set stay exact.

This format is accepted only as a preparation requirement with physical selection checking. Ordinary query and state-proof validation cannot consume it. A successful revision retains the original objects and returns strict new snapshots; the existing one-use cache still refuses changed or failed callback results. Initial requirements and recovery records have separate digests, native revision IDs use version 7, and preparation baselines use version 9. Later-form paths keep their earlier formats.

The existing fresh-edit review requirements continue through an accepted answer and an unstarted revision. Every refreshed field still needs a current explicit edit intention and a source-backed form proposal. The first actual execution creates the first real form receipt. If the desired value already matches, ordinary native verification can produce the first state proof without typing; neither recovery nor review supplies that proof.

## Prepared coverage and allowed checks

Nine methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). One earlier unchanged/unsupported boundary case was renamed and updated. All are authored and unrun:

1. Complete capture and interruption after fields, binding or preservation; recovery retains the original capture and creates only the first real execution stage.
2. Value changes to the requested value and caret-only changes while already matching; a fresh proposal/proof is required, with no unnecessary input.
3. Interruption before any initial field capture; the first observed value is used without inventing a refresh record.
4. Changed writable/read-only preservation, replaced fields and changed metadata still prevent recovery.
5. An initial host frame cannot claim empty history after native input or a native state proof exists.
6. A native ledger reset after fresh action review prevents revision.
7. Pause during either empty-history inspection or binding prevents publication and further native work until handback.
8. An accepted answer and an unstarted revision preserve the original capture, answer and first-stage identity.
9. Driver recovery after a stale initial form-planner reply produces a new proposal and one real input before the controlled query.

The revised unchanged-capture case allows read-only history inspection, asserts no fabricated refresh or input, then explicitly resumes the retained initial input before executing its original proposal.

Four changed Swift files passed `swiftc -frontend -parse`. The assembled DOM, five embedded fragments and 55 distinct fixture scripts passed `node --check`. Source inventories select 1572 default / 889 focused methods: nine additions and exactly one reviewed rename each. These are syntax and source-inventory checks, not compilation, assertion results or real browsing evidence.

## Remaining repair order

- Reconcile unknown and failed native revision captures without discarding a started callback or retrying private capture under changed arguments. Empty input history does not imply that every private read attempt is unstarted. The subsequent [uncaptured-revision checkpoint](BROWSER_UNCAPTURED_REVISION_RECOVERY_REVIEW.md) handles only explicit native pre-capture rejection; uncertain and partly captured attempts remain held.
- Continue explicit goal supersession, conflicting answers and justified replacement of earlier invariant, preservation and read duties. Initial refresh does not make those obligations disposable.
- Complete login document transitions, required-object replacement and dependent-control reconciliation while preserving task and effect history.
- Continue independent research-result verification and the full [repair checklist](../../../TODO.md). Provider login, real travel/concert/movie tasks, alternate-model comparisons, desktop adaptation and the 8 GB resource target remain unqualified and deferred to the required execution permission. No assertions, app/browser execution, inference, SSH retry, push or installed-app replacement occurred here.

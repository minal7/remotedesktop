# Native field revision from retained preparation

Status: source foundation. The owner does not yet apply this operation to a revised form input, and the driver still holds execution after revised metadata review. No assertions or live model/browser qualification ran.

## First principles

An answer may make a previously deferred field necessary. The application needs to add that field without erasing what it already knows. An old field value is a baseline, an input receipt records an event, and a revised semantic review proposes future work. None can replace the others. In particular, an unexecuted preparation may legitimately have zero input receipts; treating it as a verified query continuation would grant authority it has not earned.

## Source changes

[Native DOM and adapter code](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) adds `reviseFormFields` and a separate `ComputerUseBrowserPreparedFormRequirements` value type. Only the original sealed adapter can construct these requirements from retained form evidence. Their digest binds the document, original goal and reviewed scope, original preservation, previous continuation, field baselines and native input ledger. Private values and identifiers remain host-side; descriptions are redacted. This operation does not dispatch input or prepare a query.

Before extending the catalogue, native code checks all original fields against their original objects, values, labels, text selections and option identities. It also checks the original preservation guard and every currently active preservation record. The native ledger must match exactly: zero through 64 supplied input operation IDs, each dispatched, no unaccounted operations, and no pending change events. Equal visible values cannot recreate lost receipts. Prepared requirements explicitly carry a separate kind and are rejected by verified form inspection and query preparation, including when earlier receipts exist.

The extension retains every original field and receipt while adding explicitly selected controls from the same form and explicit editable preservation controls. It commits only a complete catalogue. It does not decide whether earlier field purposes have been superseded or whether new obligations authorize subsequent edits; that decision still belongs to the retained parent preparation and its fresh semantic review.

A native revision ID binds the prepared requirements and revised scope digest. A bounded map of at most 32 revisions pins each attempt's arguments and outcome. An attempt is recorded before new private field reads. A successful retry must retain the same active revision, native bindings and complete captured snapshots. Changing newly captured values rejects reuse instead of taking a new baseline. Changing arguments under an existing ID or trying to reactivate an older revision also rejects. Failed or unknown attempts remain terminal for that ID. This does not by itself prevent a future caller from inventing a different ID after failure; parent integration must retain the failed phase and all observations rather than using a new ID to bypass it.

[Callback capture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) now permits this preparation operation. The adapter requires a capture, joins the native callback after cancellation, preserves original target correspondence, and rejects changed arguments on reuse. There are two distinct retry boundaries: a fresh native call verifies the pinned revision, while reuse of a completed host capture returns historical data without another native observation. The latter must be bound against a fresh page before it can become an executable input. Returning a capture is not proof that the page is unchanged.

## Prepared coverage and source checks

Thirteen methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). They cover:

- Adding a deferred select to a zero-receipt preparation while retaining the original text field and readonly guard; host and native retry reuse.
- Changed newly captured values; historical host captures requiring fresh binding; changed original values, selection and native objects.
- Original readonly preservation, cancellation and callback joining without duplicate discovery or input.
- Retained verified earlier receipts; extra unaccounted input despite restored values; lost native ledger despite matching values.
- Rejection of prepared requirements by query preparation and verified inspection, with and without earlier receipts.
- Changed revision arguments, old-scope reactivation and foreign adapters.

Fixture assertions use native option IDs and their observed labels, rather than HTML option values. Prepared option-label checks use the existing 512-byte limit. These details were corrected during source review; no assertion result is implied.

Three changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 16 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,404** source methods and the [focused inventory](browser-control-state-inventory.json) selects **721**, adding 13 identifiers and removing none. Documentation links and whitespace are checked.

No build, typecheck, test assertions, app/browser/computer-use launch, inference, SSH retry, held-out inspection or installed-app replacement was performed. No scratch artifact was retained. Runtime behavior, access/type correctness, actual model judgments, context fit and real websites remain unqualified.

## Required integration and remaining repairs

1. Publish a retained revision phase on the parent preparation before any native work. Keep the original prepared input available; after extending the target catalogue, do not rerun original full-field preparation, whose field count and scope describe the old catalogue. Resume the retained revision phase instead.
2. Bind captured new fields against current metadata and validate original guards, sources and input history. Carry new observations and newly recognized preservation through subsequent answers, partial reviews, cancellation and unknown outcomes. A failed phase cannot be discarded to obtain another baseline under a new ID.
3. Construct a revised form input with explicit provenance for retained extra fields and newly needed controls. Reconcile changed or superseded purposes without assuming meaning from source overlap, losing still-required criteria or assigning an earlier observation time to a newly captured value. Keep old baselines separate from new edit authority.
4. Route only a completed, current revised input into the planner/executor. Cover stale proposals, ownership changes and repeated interruption at each phase before calling this path usable.
5. Continue document/process/account-login recovery, broader criterion lifetimes and independent result verification. Qualify travel, concert and movie workflows and actual lightweight models only after explicit execution permission. Model replacement/adaptation remains an option after measured failures; performance work remains deferred. Continue the [repair TODO](../../../TODO.md) and [scope review sequence](BROWSER_PREPARATION_SCOPE_REVISION_REVIEW.md).

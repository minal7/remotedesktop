# Verify requested form values without generating input

Status: native and host source foundation. Parent-stage and query integration, compilation, assertions and model/browser qualification remain pending.

Follow-up: [parent and query integration](BROWSER_FORM_STATE_INTEGRATION_REVIEW.md) now connects this proof in source to retained research stages, later criteria and query authorization. Execution qualification and mixed-stage repairs remain pending.

## First principles

An edit receipt answers whether a specific input operation was dispatched. A value proof answers whether particular native controls currently have the requested values. Neither implies the other. If a search form already contains the requested query or category, generating an input event merely to satisfy an edit ledger is unnecessary and can invoke site handlers. Conversely, treating matching bytes as an input receipt corrupts recovery and can conceal an earlier uncertain operation.

This repair adds a separate observation path. It leaves the generic text transaction's dispatch requirements intact and does not yet route the research driver through the new path.

## Source design

[FormStatePlan](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) compiles desired values from an exact validated, reviewed form proposal. It reuses the existing contract compiler for goal/source binding and native option identities without executing the contract. Its digest binds the desired values, captured input, review, prior criteria and preservation through the existing contract identity. Questions, unavailable proposals and unresolved pending edits cannot become plans. `capturedValuesMatch` is a historical byte comparison, not a current proof. Native selects use retained option IDs, not labels or HTML submission values.

[The native DOM adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) adds `verifyFormState` and `validateFormState`. Verification requires the current reviewed page, same native form, complete captured field catalogue, original binding objects, values, metadata, choices and initial selections. Original readonly/native preservation must remain valid. The native ledger must contain exactly the earlier dispatched input IDs, with no unaccounted operation or pending notification. Desired criteria are bounded to eight fields and 8,192 UTF-8 bytes per value; all must belong to the selected form.

Matching values produce a tiny private proof in an independent map bounded to 32 records. Differing requested values produce `form-state-needs-input` without a proof. A stale original observation is an error, rather than permission to adopt a replacement baseline. Neither outcome focuses a control, sets a value, dispatches input/change, appends an operation, or prepares a query. New field discovery and document-root replacement clear these records.

A verification ID pins canonical argument content and its original native bindings. Retrying unchanged content can return the same proof only while those requirements remain valid; changing its plan or desired values rejects. Native revalidation checks the complete retained catalogue and ledger again. Caret movement after the initial verification does not change a value criterion; all other captured metadata and values remain required. This exception is limited to state-proof revalidation and retry. Initial preparation and generic edit preconditions retain their selection checks.

The host proof constructor is sealed to the adapter and binds document, ledger, plan, goal revision, review and native preservation. Plan and proof descriptions omit private values. [Read capture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) retains the dispatched verification callback across cancellation. Reusing it returns historical evidence; fresh `validateFormState` cannot use a capture. Both host operations join dispatched callbacks before returning an error. [Reply decoding](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) confines the proof payload to its verification command and rejects private payloads on authentication-required responses.

Existing query requirements still require actual input receipts. The new proof cannot be passed as an edit continuation or convert prepared requirements into query authority. The next integration must add an explicit alternative with its own freshness checks.

## Prepared coverage and source checks

Twelve methods were added to [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). Authored fixtures cover matching text and native selections, mismatched desired values, host/native retry, cancellation, later caret movement, changed values, replacement controls, violated preservation, earlier actual receipts, an extra input, replacement ledgers, adapter/input mismatch, changed verification arguments, reply ownership and rejection of prepared requirements as query authority. An existing capture test now also rejects capturing fresh validation. Initial-value fixture options default to the original empty query and All category.

Five changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and 20 distinct literal fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,437** source methods and the [focused inventory](browser-control-state-inventory.json) selects **754**: twelve identifiers added, none removed. Documentation targets and whitespace are checked. These checks establish syntax and source-inventory correspondence, not type correctness or passing behavior.

No build, typecheck, assertion execution, app/browser/computer-use launch, inference, SSH retry, held-out inspection, push or installed-app replacement occurred. No scratch artifact was retained.

## Remaining repair sequence

1. Integrate state proof into retained parent-stage execution, cancellation/handback and explicit query preparation. Distinguish verified desired fields from actually edited fields and retain their source purposes. A later matching value cannot erase an uncertain earlier effect.
2. Handle mixed forms containing both matching and changed fields, forms with only retained criteria, and work explicitly superseded by later user instructions. Preserve all original invariants. This first path uses exact requested bytes and native choices; semantic numeric equivalence and wider control types need deliberate rules.
3. Reconcile preservation first discovered after earlier effects, changed controls/documents, process recovery and login/account transitions. A present match does not prove an unobserved earlier interval or successful account handoff.
4. Compile and run the prepared coverage, then qualify real travel/concert/movie tasks and actual lightweight models only after explicit execution permission. Alternate-model evaluation and authorized RTX 3080 adaptation remain available after measured failures. Performance work remains deferred. Continue the full [repair TODO](../../../TODO.md).

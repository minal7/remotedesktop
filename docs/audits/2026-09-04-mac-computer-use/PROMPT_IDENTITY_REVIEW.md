# Bind durable task identity to the original instruction

Parent source: `c83e263`. Status: source repair and regression registration only. No compilation, XCTest execution, model inference, application launch, computer-use activity or installed-app replacement ran. Performance optimization and live travel/concert/movie acceptance remain deferred.

## First-principles defect

A task ID identifies one instruction. Replaying a result or resuming saved work is justified only when the caller presents that same instruction under the same controller and session. Matching an ID alone cannot establish this.

`ComputerUseTaskLedger` previously retained the task ID, sender/session, control revisions, execution state, terminal result, clarification and approved-action record. It did not retain an identity for the prompt body. `HostComputerUseManager.startExecution` claimed the ID before decoding the incoming request.

Two concrete consequences followed:

1. Pause could arrive before Prompt A. The ledger claimed A without starting it. Prompt B with the same ID/sender/session then also returned `paused`, and the manager replaced its retained execution context with B. Resume could execute the replacement instruction under A's task ID.
2. A changed request could receive A's completed result, clarification reference or approved-action evidence. An accepted request reconstructed after a restart could also project A's confirmed approved action as completion of B. Native and visual executor checks did not cover these manager paths because replay happens before executor dispatch.

The exact request includes conversation, clarification identity and protocol capability fields. Comparing only the displayed prompt, normalized Unicode or reconstructed JSON would leave parts of the request unbound. The current phone sender already encodes once and retains the exact body for retries.

## Repair

- Every production ledger claim now requires the raw prompt body. The ledger stores SHA-256 of its exact UTF-8 bytes in the same atomic write that claims the prompt. No additional prompt text is persisted.
- Sender/session and body identity are checked before accepted status, paused-context reconstruction, terminal replay or approved-action recovery. A changed body returns an identity mismatch without mutating the record, replacing a context, starting work or publishing an old result.
- A record created solely by a pre-delivered Pause, Resume or Cancel has received no prompt yet. Its first prompt may bind a digest. A pre-Prompt Cancel remains terminal, while a paused first prompt remains unstarted until a newer Resume. Later bodies cannot rebind either record.
- A claimed legacy record without a digest cannot acquire its original instruction from a retry. It remains retained and returns a distinct identity-unavailable result. The manager explains that the original instruction cannot be verified and asks the user to inspect the Mac before issuing a new request. It does not execute or overwrite the original terminal result.
- The outbound projection also gates legacy control replies, which have no prompt body. These replies cannot present an old success, clarification or action evidence as confirmation of the incoming instruction. The recovery response carries `unableToComplete`; Cancel still receives its durably applied control revision. Existing Cancel semantics continue to retire clarification. Original action evidence remains in the ledger for future reconciliation.
- New approved-action claims require a recorded prompt digest. Existing result retention is preserved. Malformed non-nil digests or impossible unclaimed/started state poison ledger loading instead of making work executable. Partial legacy ownership cannot overwrite a sender or session that was already recorded.
- Storage-error copy no longer asserts that no action ever occurred: a failed retry check cannot establish that historical fact. The host says it cannot safely record or verify the request and will not start another attempt.

An identity conflict is currently ignored on the wire, as foreign task identity already was. Sending an ordinary terminal response for the conflicting delivery could terminalize the phone's original task while the Mac is still executing it. A future correlated rejection message should distinguish a rejected delivery from the lifecycle of the original request. This patch does not add that protocol or UI.

## Prepared regressions

Eight new methods in `ComputerUseTests` cover:

1. Accepted and completed replay after reload, with body changes to whitespace, Unicode normalization, conversation, clarification reference, capability fields and the instruction. Conflicts must leave the on-disk record byte-for-byte unchanged; exact retries retain their behavior.
2. First-prompt binding after Pause/Resume/Cancel, conflicting bodies before and after Resume, and the original paused task starting once.
3. Legacy accepted, paused, completed, unbound and partially bound records. Retries cannot establish missing identity or start an approved action; a known sender remains enforced.
4. Failure while writing the first prompt digest to pre-Prompt Pause/Cancel records. The in-process ledger remains poisoned after storage returns, while a reloaded ledger retains only the state actually written.
5. Malformed digests and invalid associated identity/state cannot load as new executable work.
6. Production manager handling of Pause → original prompt → changed prompt → Resume. Only the original trusted instruction reaches the fixture executor; conflicting retries during active work do not terminalize it.
7. Changed-body replay against completed, clarification, confirmed-action and unconfirmed-action records. Only an exact retry receives a terminal update and the corresponding evidence; no executor runs.
8. Legacy prompt and Cancel replies expose recovery guidance without old clarification or action evidence. The original result and approved-action evidence remain stored.

All 34 existing direct ledger claim fixtures now supply a body; fixtures tied to a manager envelope use that envelope's exact body. The focused selection also retains existing ordered-control, clarification, approval, storage and interruption cases. A queued control status acts as a delivery barrier in manager regressions, so the negative assertions inspect all earlier replies rather than relying on a single scheduler yield.

## Verification and remaining work

Source inventory checks match **537 default** and **43 focused** identifiers; `git diff --check` passes. See [the focused inventory](prompt-identity-inventory.json). The changed Swift files were already registered in the project. These checks do not establish compilation or runtime behavior.

When execution is authorized, compile and run the focused cases, then qualify real phone retry/relaunch, ordered controls and host restart through authenticated transport. Legacy records need an explicit historical reconciliation experience before users can recover their full history in the client.

This repair binds the instruction at the durable host boundary. Complete visual/structured task contracts, future entity bindings, per-step TYPE/Return authority, actual submission/search receipts and independent whole-goal completion remain open. Existing ledger retention limits, cross-process storage ownership and crash durability also remain separate recovery work. No exactly-once, live ticket-finding, 8 GB or thermal qualification follows from this source patch.

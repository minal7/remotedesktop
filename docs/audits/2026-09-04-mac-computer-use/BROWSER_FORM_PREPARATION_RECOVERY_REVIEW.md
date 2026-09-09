# Retained private form preparation

Status: source repair; native/runtime/model execution and broader parent recovery remain unqualified.

## Failure and repair

The owner previously held the first form preparation only in a cancellable local call. WebKit can finish a dispatched script after Pause has cancelled its waiter. Its private field/readonly results were then discarded before `PreparedForm` existed. Rediscovery would either fail against an active native guard or replace an earlier value baseline. A native callback completing and a caller successfully returning are separate events.

[DOMReadCapture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) now retains the result independently of the waiting task. It accepts only `formFields`, `bindPageFields` and `prepareFormPreservation`, never input, popup, option or scrolling effects. The original document, command and argument digest bind each capture. Only the observation nonce may differ on reuse; selected control IDs, scope purpose and ledger arguments cannot change. A retained reply is historical data, not proof that the current page still matches.

[The owned browser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) decodes a returned result into that capture before waking native-completion joiners, including when the caller was cancelled or timed out. The existing native slot remains occupied until callback or close. Closing records failure rather than pretending no read started. An unknown/malformed failure stays terminal for that capture; it cannot become permission to take a new baseline. A verified empty authentication reply can release an unobserved capture for a later retry because these three commands check authentication before their private readings. The caller still needs ownership and original-page validation. The shared decoder now also rejects preservation payloads on other commands or authentication replies.

[ResearchFormPreparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) retains the exact reviewed action, interpretation, original page, native adapter and three capture phases **before** the first private read. It stores completed fields/correspondence/preservation as each phase returns, compares correspondence to the original captured fields, and keeps the completed input before final validation. Resume restores original metadata/read scopes, adopts captured results without rediscovery, and validates current native identities and values before planning or editing. A changed field or readonly value cannot become the new baseline.

[The owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) exposes this as pending form preparation until an execution stage takes ownership of the same input and adapter. It survives Pause, blocks competing research work and is discarded on retirement. [The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) resumes it before requesting another action selection. An already ready input also survives cancellation in form planning. The owner and stage share [original-page restoration](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift), with metadata checked before another private field comparison.

A new clarification answer may discard an unstarted preparation only when it has no preservation or retained-read obligations. Frames with such obligations remain retained; reconciling them with a revised goal is still pending. This preserves ordinary unconstrained form-question behavior without silently dropping known invariants. Legacy unreviewed discovery and later-stage extension preparation keep their existing paths.

## Prepared coverage and source checks

Ten new methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) prepare coverage for:

1. Pause at each of the three native preparation reads, followed by explicit handback, captured-result recovery and one input.
2. A changed captured editable value blocking recovery before readonly capture or editing.
3. A changed captured readonly value blocking recovery of unpublished preparation.
4. A replacement field failing to inherit authority from captured data.
5. Cancellation during final original-input validation retaining the same prepared input.
6. Driver resumption completing the retained stage before asking for another action.
7. Owner retirement preventing a late callback from publishing a stage.
8. Captures rejecting effects and changed arguments while allowing a new observation nonce.
9. Unknown read failures never becoming absent observations or fresh capture attempts.
10. Only empty authentication replies allowing retry; preservation-bearing authentication replies and wrong-command payloads rejecting.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,361** source methods; the [focused inventory](browser-control-state-inventory.json) selects **678**. Ten identifiers are added without removing earlier coverage. Eight changed/new Swift files receive `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and six distinct fixture scripts receive `node --check` only. Each of the two new production files has four Xcode registrations. Project syntax, source inventories, documentation links and whitespace are checked.

These methods have not executed. Source parsing does not prove Swift type correctness, native callback timing, actual model decisions, context/tokenizer fit or website behavior. No build, typecheck, assertion run, app/browser/computer-use launch, inference, SSH retry, held-out inspection or installed-app replacement occurs. No scratch artifact is retained.

## Remaining repair order

1. Apply retained preparation to **later-stage extension** and reconcile original preservation/read obligations across clarification and goal reinterpretation. The initial reviewed preparation now survives same-goal interruption; an invariant-bearing frame cannot yet continue under a changed goal. Do not discard it or reset its native guard to hide the gap.
2. Complete durable parent/browser/account-session recovery across process restart and explicit owner transfer. This checkpoint retains preparation and callbacks in memory. A contract hash and a callback capture do not recreate an old native document after a crash or prove an unknown callback failure succeeded. Visible login takeover and explicit handback remain required; real account qualification remains deferred.
3. Complete composite/custom predicates and criterion lifetimes across popup/selection effects, navigation and document replacement. Original-page restoration remains conservative about unrelated page changes. Distinguish meaningful criterion changes from changing decorative content without weakening original value/identity obligations. Native frontend predicates cannot prove transient unobserved property changes or backend behavior.
4. Verify independent travel/concert/movie results against the full request, then qualify actual lightweight-model judgments and supported website workflows after explicit execution permission. Whole-app 8 GB memory and thermal qualification remains deferred. Alternate models and the authorized RTX 3080 are available for later measured model work; no substitution, pruning or distillation is established by this checkpoint. Continue the [repair TODO](../../../TODO.md).

# Approved task-step journal — source repair

Status: implemented as a journal/API foundation after 6aacd24. Compilation, tests, model execution, app launches, computer use and live websites remain paused. The normal host approval path still uses the legacy single-action API; this change does not enable automatic multi-step natural-language execution.

## First-principles finding

An operation's arguments do not identify an occurrence of that operation. A request to create the same draft twice needs two effects. A retry after a lost response needs the receipt for the original effect. Both cases can have identical arguments, so task ID plus arguments cannot distinguish them.

The host also needs the sequence of confirmed effects. One mutable latest-action slot cannot preserve multiple approvals, associate a late response with its step, or establish which step may run next. Removing the single-action restriction without replacing those guarantees could duplicate earlier effects or skip an uncertain one.

## Implemented source change

- `MCPToolCall` carries an optional host task-contract `stepEffectID`. Scoped calls require an approval-required risk and a 64-character lowercase hexadecimal identity. The canonical call digest includes that identity, so two intentional occurrences have distinct mutation-ledger entries. Retrying the same step across helper generations retains its digest; its approval fingerprint still binds to the active generation. Unscoped calls retain their previous canonical identity and encoded compatibility. The identifier is host metadata and is not sent as a tool argument.
- The pool reconstructs the complete scoped call against current tool policy before approval or execution. Approval for one step cannot authorize another, even when their arguments match.
- `ApprovedActionPlan` projects the approved calls from an already host-bound task contract. It binds the exact original prompt body, the full contract digest, each ordered effect ID and its canonical call digest. Its factory checks the contract's decoded-prompt digest, target server/tool/schema authority, payload digest and version, and exact contract step identity. Plans contain at most 64 unique steps. Models do not produce or choose this authority.
- The scoped claim API stores the fixed plan and ordered action history atomically before returning a new claim. It permits only the next index after a confirmed prefix. An unconfirmed step blocks advancement. Changing the plan, prompt, call identity or sender/session fails; a legacy claim cannot be reinterpreted as a scoped plan.
- A retry returns the recorded occurrence. A new helper generation cannot overwrite the old approval fingerprint or use its new fingerprint to confirm the old dispatch. The future driver must reconcile the retained occurrence instead of dispatching it again.
- Confirmation updates the exact fingerprint in the history. A late duplicate for an earlier step cannot replace the latest action. Stop remains terminal, Pause blocks new claims, and a valid late confirmation can be retained without restarting execution. Storage failure poisons further use of that ledger instance.
- The existing `approvedAction` field remains a latest-action projection for older readers. Reload requires it to match the tail, including exact response bytes; plan identity, effect order, confirmed-prefix shape and timestamps are validated. A damaged scoped history does not fall back to legacy interpretation.
- Retention now considers dispatch and confirmation times as well as task creation. An old task's unconfirmed effect remains pinned; a newly received late confirmation is not immediately pruned because the request was created long ago.
- Scoped confirmations cannot carry the legacy single-Mail whole-task proof. Even a matching literal Mail action inside a plan requires the separate contract outcome verifier. Host confirmation lookup now asks for the exact fingerprint rather than assuming the just-confirmed action is the latest one.

This journal verifies approval order and stores facts supplied by the host. It does not observe external preconditions, verify non-approved intermediate steps, infer login state or prove all task outcomes. The full contract digest pins that broader specification; it does not establish that its predicates are true.

## Prepared verification

Seven new test methods cover:

1. Distinct scoped identities for identical arguments, stable identity across helper generations, legacy encoding and invalid/read-only scope rejection.
2. Two approved occurrences through a fake pool, rejection of a cross-step approval, durable receipts and no replay after helper restart.
3. Ordered claims, blocking an unconfirmed prefix, exact historical lookup, late duplicates and generation-specific confirmation.
4. Rejection of changed prompt, graph, order, payload, schema authority, sender and legacy scope.
5. Pause, Resume, Stop, late confirmation and restart history preservation.
6. Failed storage of the next claim or its confirmation without publishing uncommitted state.
7. Reload rejection of broken history, missing plan, skipped confirmation, changed scope, differing alias bytes, per-step task proofs and missing confirmation times; retention of a recent confirmation for an old task.

The existing literal-Mail proof method also asserts that scoped action confirmation cannot become whole-task proof. The reviewed default source inventory now selects **676** methods: seven new methods and two existing canonical-identity/ambiguous-mutation methods newly selected since the previous 667. The [focused inventory](approved-step-journal-inventory.json) selects **45** methods, including existing approval, interruption and mutation-replay checks.

Syntax-only parsing of seven changed Swift files, both source-inventory checks and whitespace checks pass. These are source checks; no assertions ran and Swift type correctness has not been established.

## Remaining repair sequence

1. Compile the complete original request into host-bound operations, constraints and outcome predicates. Broader browsing, account context and complete travel/concert/movie results remain unimplemented or unqualified.
2. Integrate scoped approval plans with the task execution driver. Observe fresh prerequisites before each effect, retain verified results and remaining goals, reconcile uncertain effects, and request each later approval separately. The existing host path deliberately continues to use the legacy API until that driver exists.
3. Integrate the ordered history with phone evidence and approval controls. The current presentation has one approved-action record per task. It cannot yet present or resume the complete multi-approval sequence.
4. Preserve the same remaining-goal contract across visible login takeover and explicit handback. Refresh ownership, document and account evidence before continuing. Provider/window behavior and post-login task continuation still need qualification.
5. Establish serialized cross-instance/process ownership before qualifying this journal for competing writers. `ComputerUseTaskLedger` currently caches a whole-file map; atomic file replacement alone does not provide the compare-and-advance or execution-lease guarantees implemented by the separate generic task journal. The new tests cover sequential reconstruction and failed writes, not competing writers or power-loss durability.
6. After explicit authorization, compile and run controlled regressions, then qualify the complete host/phone workflow. Real-site ticket scenarios and 8 GB/thermal qualification remain deferred. No universal natural-language correctness claim follows from this foundation.

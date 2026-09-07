# Approved action evidence and whole-task scope — source repair

Status: implemented in source, with compilation and execution still paused. This follows 14ff2be. No test, model, application, computer-use session or real website was run.

## First-principles finding

An action, its confirmation and the user's complete goal are different objects. Approving one precise Mail call authorizes that call. A successful response can confirm its result; it cannot establish that a second requested action, a search, a comparison or a result report also happened.

The previous path collapsed these facts in three places:

1. MCPFirstComputerUseExecutor accepted any non-error approved tool result and returned ComputerUseExecutionResult.completed, using free-text tool output or a generic success sentence.
2. HostComputerUseManager required that terminal result and persisted its text as the approved-action confirmation. It then marked the original request completed.
3. Resume and restart reconciliation treated any stored approved-action response as whole-task success, including legacy records that contained no task-completion proof.

This was not only a wording problem. The phone received a task-completed outcome, so work after the approved action could disappear from the task lifecycle. Starting the planner again without changing the contracts would introduce another problem: the current host ledger admits only one approved action per task and does not preserve a verified sequence of remaining goals.

## Implemented source change

- The approval continuation protocol and capability wrapper now return MCPApprovedActionResult, an action confirmation independent of ComputerUseExecutionResult. Cancellation cleanup preserves a returned, validated action fact without granting further work.
- The reviewed embedded Mail adapter accepts only its own server/tool identity, an approval-required call, valid Mail arguments, an untruncated non-error result and exactly the matching typed status. Draft opening cannot confirm sending, and sending acceptance cannot confirm draft opening. Missing/unknown/contradictory status leaves the already claimed effect unconfirmed; it cannot be retried.
- Confirmation text is projected by host code. It says Mail accepted the email for sending or opened the draft for review. Tool prose cannot claim delivery, completed ticket research, extra effects or whole-task success.
- A complete literal single-Mail command can establish a task-completion proof. It must specify one exact recipient, a quoted subject and quoted body, and the send/draft operation must match. Every captured value uses exact UTF-8 equality. Extra recipients, other clauses, changed bytes, negation and explanatory requests do not inherit that proof. Instructions inside the explicitly quoted body remain message content.
- This bounded proof family is not the general natural-language task compiler. Other approved requests retain action-only evidence. They receive an unable-to-complete task outcome explaining that the full request remains unverified, rather than a false task-completed outcome.
- The durable approved-action record has an optional completionPromptDigest. Confirmation and its completion scope are persisted together and immutable: a later caller cannot upgrade an action-only record or downgrade an existing proof. Malformed stored proofs fail record validation.
- The host checks the returned call identity and exact trusted-prompt digest before recording confirmation. A matching proof is required again on Resume and restart replay. Legacy action records have no proof and cannot be promoted into whole-task completion.
- Stop remains the first terminal outcome even if a later valid action confirmation includes a completion proof. Existing evidence-only updates still annotate that action without restarting automation or changing the terminal outcome.

No phone protocol change is needed: confirmed action evidence and task outcome were already separate wire fields. Existing terminal records are not retrospectively rewritten; the repair prevents new promotion of an action record into an unsupported completion claim.

## Prepared checks

Six new methods cover:

1. Matching typed Mail results, foreign servers, missing/extra/contradictory fields, truncation and host wording independent of tool prose.
2. Exact complete-command proof, byte distinctions, additional goals and recipients, and commands quoted as message content.
3. A compound request returning one action fact without a whole-task proof or reusable approval.
4. Optional/immutable stored proof, validation on reload and a late proof preserving Stop.
5. Restart replay with legacy action-only evidence, matching proof and a proof for another request.
6. Fresh host approval with action-only evidence, full proof, another task's proof and another call's identity.

Existing planner, deterministic Mail, capability-wrapper and interruption fixtures now use typed Mail confirmations. Pause/Resume coverage now expects an unverified task outcome when the retained action has no whole-task proof; the confirmed action and its no-replay behavior remain asserted.

The default source inventory selects **667** methods: six newly prepared methods and four existing approval methods newly selected since the previous 657-method inventory. The [focused inventory](approved-action-scope-inventory.json) selects **35**. Both source inventory checks, syntax-only parsing of eight changed Swift files and whitespace checks pass. No assertions executed; these checks do not establish Swift type correctness, runtime cancellation behavior or host/phone rendering.

## Remaining repair sequence

1. Build the full task compiler and outcome verifier around the original request. Its requirements must preserve all requested actions, constraints and result requirements. Replace the bounded single-command completion proof only when broader requirements can be represented and checked.
2. Replace the host's single approved-action slot with a durable ordered step journal. Each approval must bind to its own task step, exact effect identity, prerequisites and confirmation. One approval must never authorize another step.
3. Retain structured planning state and verified results across approved actions. Resume from confirmed progress rather than reparsing the original prompt as fresh authority. Uncertain effects require reconciliation before further dispatch.
4. Continue verified remaining steps after recording the current action, with fresh ownership, cancellation and authentication checks. Support further approvals and login handoff while preserving the original task. This change does not yet provide that automatic continuation.
5. Combine action receipts with complete result predicates for browsing: identity, dates, locations, availability, counts, prices/fees and selected public sources. Neither a page change nor an accepted Mail action verifies those requirements.
6. After explicit authorization, compile and execute controlled regressions and qualify the installed host/phone flow. Keep real travel/concert/movie tests deferred. Performance optimization and 8 GB/thermal qualification remain in the later phase.

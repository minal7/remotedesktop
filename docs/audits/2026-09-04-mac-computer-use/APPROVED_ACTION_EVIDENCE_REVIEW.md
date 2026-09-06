# Show approved-action evidence without changing task ownership

Parent source: `a315a3c`. Status: source implementation and fixture registration only. No build, XCTest execution, model inference, app launch, installed-app replacement or computer-use activity ran. Performance optimization and real-site acceptance remain deferred.

## First-principles problem

An instruction to stop, a confirmed result from an already-approved action, and the completion of an entire task are three different facts. The prior repair preserves the action result in the Mac's durable ledger even if Stop has already become the task's terminal response. The phone, however, normally accepts updates only for its active task. Reusing an ordinary terminal reply for a late confirmation would either hide that fact or let an old task change the current task's state.

This repair adds typed historical metadata. A confirmed action can annotate its original request while Stop remains the terminal reply and a newer task keeps its own controls, approval and outcome.

## Wire contract and compatibility

`ComputerUseApprovedActionEvidence` contains an opaque action fingerprint digest, `unconfirmed` or `confirmed`, and an optional bounded summary/full-result digest. Unconfirmed records have neither summary nor result digest. Confirmed records require both. Digest strings must be exactly 64 lowercase hexadecimal bytes; summaries must be nonempty and fit 4,000 characters and 16,000 UTF-8 bytes. Decoding invokes the same validation as construction.

`ComputerUseTaskUpdate` gains optional evidence and an `isApprovedActionEvidenceOnly` marker. A marked update must contain evidence, empty text, and no control revision, terminal outcome or clarification. The decoder also rejects a raw future outcome or mismatched clarification that ordinary compatibility decoding would otherwise discard. Such metadata is carried in the existing status envelope; it cannot acknowledge Pause/Resume/Stop or report a task outcome.

The prompt payload gains `supportsApprovedActionEvidence`, defaulting to false for old structured and plain-text prompts. The current phone advertises it for ordinary requests, legacy conversational answers and exact scoped answers. It remains outside model input, and existing exact-body retry/recovery continues to reuse the saved bytes. Only an opted-in request receives standalone evidence updates. Other peers continue receiving their existing lifecycle messages, with optional evidence that older decoders ignore. No envelope kind or required legacy field changes.

The field limits bound accepted metadata, not allocation of the whole incoming JSON envelope. The full result digest is an opaque conflict identifier supplied by the authenticated host; a phone cannot recompute it from a truncated summary. It is not an additional authentication mechanism.

## Host behavior

After the durable approved-action handoff is claimed, the manager queues unconfirmed evidence. After a confirmed continuation result has been durably recorded, it queues confirmed evidence, independently of the old execution token. Ordinary assistant/status replies also carry a current ledger snapshot; an authenticated replay after host reconstruction can therefore include confirmation while retaining the original Stop response and control revision.

Summary presentation respects both byte and character limits, including compound Unicode characters. An empty response, or a first character that alone exceeds the wire limit, uses a fixed confirmation sentence. The full result digest still comes from the retained ledger record. No additional tool arguments cross this surface.

Standalone pushes capture the original transport and authorization generations. They require the same currently authorized peer both before enqueueing and after any preceding delivery finishes, immediately before calling the channel. Revocation or transport replacement invalidates the queued push even if the same peer is authorized again. This does not retract a send already handed to a transport, change existing terminal-delivery teardown semantics, or replace transport authentication. The durable host record remains available if a push is skipped or delivery fails.

`confirmed` means the existing approved continuation returned a completed result that the host persisted. It does not independently prove a real Mail mutation, verify every requested outcome, or provide exactly-once execution across a crash.

## Phone behavior

Evidence attaches only to a user message whose ID matches the task ID, from the model's exact host, pairing and session. Lifecycle handling still performs its existing active-task and control-revision checks independently. Evidence-only status updates bypass that lifecycle handling; evidence-only assistant envelopes are ignored.

The first record may already be confirmed. After an unconfirmed record, only confirmation for the same action ID is accepted. Duplicate records, regressions to unconfirmed, different action IDs and conflicting confirmed responses do not replace retained evidence. Updates do not add chat turns, change the composer, clear a retry, acknowledge a control, consume an approval or reset task progress/outcome. Malformed JSON status bodies are no longer interpreted as legacy progress text.

The original message bubble displays either “Action result not confirmed” or “Action confirmed on Mac”, with the uncertainty explanation or bounded summary. The annotation has its own combined accessibility element. Conversation scrolling now follows a newly appended message ID, so updating an older annotation does not itself scroll to the bottom. Neither annotation text nor its digests enter subsequent model conversation input.

## Prepared regression coverage

Six new host methods specify wire round trips/legacy decoding, invalid identities and summaries, separation from control/outcome/clarification, retained Stop replay with empty and large Unicode results, legacy capability behavior, and queued-delivery revocation/replacement races. Four existing manager interruption methods now also check evidence publication before/after Pause, Stop, a newer task and transport shutdown. Their controlled continuations and fake channels perform no real helper mutations.

Six new client methods exercise the actual session model through serialized fake-channel traffic:

1. Unconfirmed evidence cannot acknowledge pending Stop; confirmation may precede or follow its terminal reply without changing the outcome.
2. Historical confirmation and obsolete terminal replay leave a newer working, paused or approval-pending task unchanged.
3. Evidence advances once and rejects duplicate, reordered and conflicting records.
4. Foreign host/pairing/session, unknown task and wrong envelope kind cannot annotate a message.
5. Malformed status bodies and valid metadata cannot erase a retry or become task progress.
6. Requests and both answer paths advertise support while annotation text stays out of later model context and exact answer bytes are preserved.

The default host inventory grows from 518 to 524 methods. The [30-method host inventory](approved-action-evidence-inventory.json) includes the previous durable-record coverage. The [15-method client inventory](approved-action-evidence-client-inventory.json) combines the six new methods and nine existing clarification methods. Tests live in source files already registered in their projects; no project references change.

## Source checks and remaining repair order

Source inventory validation matches 524 default, 30 focused host and 15 focused client identifiers; `git diff --check` passes. This establishes source registration and whitespace consistency only. The Swift changes and fixtures have not been compiled, executed or rendered.

1. Compile and execute the selected host/client regressions when permission resumes, then qualify their composition through actual authenticated transport and the phone UI. Verify accessibility and scrolling on-device.
2. Add an explicit authenticated historical-evidence query and durable client history/reconciliation. Current finished-message annotations are in memory. A late result after disconnection is retained on the Mac, but the client does not yet automatically query completed tasks or restore those annotations after its own restart. Normal pending-prompt replay is narrower than complete history recovery.
3. Define capability-specific reconciliation for an unconfirmed handoff. A persisted claim does not establish whether a mutation was actually dispatched. Keep automatic redispatch prohibited until independent evidence resolves it.
4. Extend durable effect receipts to general native AX, visual and multi-step MCP work, including underlying helper crash boundaries and operator resolution/retention policy.
5. Continue whole-goal contracts, per-step typing/submission identity, completion predicates and the remaining natural-language repairs. Travel, concert and movie scenarios remain future acceptance cases requiring explicit permission. No 8 GB or thermal qualification follows from this patch.

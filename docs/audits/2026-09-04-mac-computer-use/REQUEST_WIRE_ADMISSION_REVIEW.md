# Admit the actual phone request at the host boundary

Date: 2026-09-07. Parent source: 262916e. This is a source repair to request admission, with prepared regression coverage. No runtime, installed-app or natural-language task qualification was performed.

## Finding from first principles

A natural-language planner cannot help if the application rejects the user's request before invoking it. The production client, shared wire decoder and privileged host admission must agree on one message schema. Passing a shared codec round trip alone does not prove that the actual host will accept the encoded message.

In the parent source, `ComputerUseSessionModel.sendPrompt` sets `supportsApprovedActionEvidence: true` for all three composer paths: a new request, a legacy conversation answer and an exact scoped answer. `ComputerUsePromptRequest` encodes this field and its decoder understands it. However, `ComputerUseExecutionPromptDecoder` kept a separate four-field allowlist containing only `version`, `prompt`, `conversation` and `clarification`.

Consequently, every newly emitted current-client prompt carrying that flag would fail the host's structural admission before policy/planning. The host then terminalizes the claimed request as invalid. This is visible directly in the source; it was not reproduced by running the app. Earlier tests checked the capability through `ComputerUsePromptRequest.decodeBody`, while many host fixtures constructed requests using the default false capability, which omits the field. That combination missed the integration mismatch. Historical passing model/browser runs do not qualify this later wire path.

## Repair

The shared prompt type now exposes `wireFieldNames` derived from its `CodingKeys` enumeration. The host's strict structural decoder uses that set, so the emitted optional capability field and host admission have the same schema owner. No encoded payload or protocol version changes. Boolean decoding and the absent/null-to-false behavior remain those of the existing shared decoder.

The host still checks the structured-body size, bounded strict JSON parsing, duplicate keys, top-level object shape, unknown fields, current protocol version and the prohibition on adding conversation to a scoped answer. Malformed structured input does not fall back to a plain-text task. The metadata field remains outside `modelPrompt` and user-text authority. Its production use is to allow optional approved-action evidence replies; accepting it does not approve an action or alter action/control checks.

The durable ledger still binds the complete exact wire body before execution. Changing the capability on a replay under the same task ID remains an identity mismatch. Replaying a request already terminalized by the old decoder preserves its existing outcome; this repair does not rewrite that ledger or automatically execute previously rejected requests. Later qualification must use fresh request IDs for new work and separately verify exact replay behavior.

## Prepared verification

- Two new decoder methods cover all three current request shapes with and without the capability, exact Unicode/whitespace answers, metadata exclusion from model input, explicit false/null values, invalid capability types, duplicate and escaped duplicate keys, unknown authority fields, unsupported versions and invalid conversation roles.
- The existing capability round-trip test now also uses the actual strict host decoder. The host's two-question continuation/replay case now advertises the capability on the original request and both answers. The existing legacy-conversation host case also uses the capability and checks that it stays out of model input.
- One new composition method uses the production client state, separately compiled client/host JSON types, authenticated local mailbox admission, strict host decoder and host manager/ledger. The fixture schedules host mailbox delivery and uses a controlled executor. It follows an original request longer than 5,000 characters through two exact answers, carries each host-issued reference back through the client, and replays each exact envelope without repeating continuation. No model, browser, helper or external service is part of this prepared case. Its executor counter and injected completion establish only the intended fixture behavior, not a real form edit or completed research task.

The new [focused inventory](request-wire-admission-inventory.json) selects **26** methods, including existing clarification, identity and approved-action interruption cases. The default source inventory selects **790**: three new methods and one previously existing legacy-conversation method were added to its prior 786-method selection. Existing Xcode sources already include all changed files and the shared protocol in both endpoint modules. The composition source is intentionally excluded from the root SwiftPM test target, so the Xcode test target is required for that case.

Five changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, app launches, model inference, browser execution or computer-use activity ran.** Prepared cases still require compilation and execution after permission. The installed app is unchanged.

## Follow-through

1. After explicit permission, compile and execute the focused request-admission tests, including the actual client composition case and the existing approval/pause/replay checks. A shared-codec-only test cannot replace that boundary check.
2. Qualify the same serialized requests through the installed phone/host transport. Verify new requests, legacy answers, scoped answers, exact retries, reconnect and terminal replay before drawing conclusions about natural-language planning.
3. Continue the [research-owner repair sequence](BROWSER_RESEARCH_OWNER_REVIEW.md): complete goal semantics, general research routing, root-preserving browser-question transport, journaled dynamic actions and result verification. This wire fix removes an earlier rejection; it does not implement those missing capabilities.
4. Keep real-site travel/concert/movie testing and model execution paused until later explicit permission. Performance work remains after correctness repairs.

# Preserve browser research through phone questions and login handback

Date: 2026-09-07. Parent source: 5bee459. This checkpoint implements host transport for typed browser questions and maps accepted answer executions to the retained original browser task. It includes prepared regression cases. **The production general research driver is still missing; no live browsing or natural-language task qualification was performed.**

## First-principles finding

A clarification answer is information about an existing task. It is not a replacement task. “Paris” must extend the original ticket request, retaining its prohibitions, date reference, browser session and effect history. At the same time, the phone needs a new message ID so it can retry that exact answer without executing it twice. The browser task identity and the transport execution identity therefore have different lifetimes.

The parent source retained a canonical browser research owner, but the host's question/answer transport only continued native text tasks. Every ordinary terminal reply retired research state. Host lifecycle and local browser controls also assumed that the current message ID was the original browser root. Simply attaching a browser question to that path would either discard the research owner or detach later Pause/Resume and login controls from its browser.

## Source repair

`ComputerUseBrowserClarificationTransport` binds the existing opaque phone reference to the actual retained owner, sealed typed question, canonical input revision and authenticated controller/session. No new client-selected browser identity or wire field is introduced. A request names a supported question topic and existing requirement IDs; the owner validates the scope and supplies fixed host question text. Login remains a user-control handoff, not a credential question.

The host consumes a matching browser answer only through `ComputerUseBrowserResearchContinuing`. It verifies actual object identity, the question's revision, controller/session and the current execution ID before appending the exact answer. The existing owner enforces expiry, answer limits and browser scope. Invalid answers do not become ordinary instructions or consume a valid pending question. Successful consumption advances the transport ID while retaining the original root, request bytes, clock and time zone. Resume uses the accepted continuation again without appending the answer again.

Only a successfully persisted terminal reply containing the exact current browser question may preserve its owner. A failed write, conflicting terminal, ordinary terminal or cancellation retires that owner. Replacement requests, transport teardown and controller changes invalidate outstanding references. Durable exact replays use the ledger response without another continuation. The bridge retains at most one question and introduces no timer; an expired mapping cannot be consumed and is discarded on replacement or teardown. References cannot restore in-memory browser state after restart.

The research owner exposes its latest accepted answer ID as `executionTaskID`. Host lifecycle calls match that ID and local browser controls map it back to the original root. Phone controls and ledger revisions remain correlated to the current answer. Host handback requirements capture the original browser session, so an accepted answer can encounter authentication, pause, and explicitly resume that same browser. Stale earlier execution IDs cannot pause or retire the newer accepted answer's owner.

## Prepared verification and actual checks

- Four transport methods cover exact Unicode/whitespace answers through the existing wire, successive questions, immutable root/time, mismatched controller/session/owner/revision, invalid answer sizes, replay, expiry, pause, retirement and current-execution lifecycle mapping.
- Four host methods cover two questions, local Pause/Resume, durable replay, stale or foreign references, cancellation/disconnect/controller replacement, new requests, persistence failure and login after an answer. The replacement case also checks that a late old answer cannot consume or retire the new question.
- The prepared login case uses a controlled loopback page that reveals authentication after the first question. It checks handback to the same root/session and one initial navigation. It does not enter credentials or authenticate with a provider.
- One composition method uses the actual client composer, separately compiled client/host wire types, local mailbox, strict host admission, manager and ledger. It preserves the original request plus two exact answers and replays each envelope without another continuation. Its controlled executor explicitly ends with inability; it supplies no invented research result.

The new [focused inventory](browser-clarification-transport-inventory.json) selects **51** methods, including prior native clarification, authentication, local-control and handback cases. The default inventory selects **799**, nine more than the parent. New source/test files are registered in the Xcode project. The actual-client composition case requires the Xcode target; the root SwiftPM test target intentionally excludes that composition file.

Nine Swift files pass syntax-only parsing, one new fixture script passes `node --check`, and project syntax, both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, app launches, model inference, browser execution or computer-use activity ran.** The installed app remains unchanged. Source inventory counts are not passing test results.

## Remaining repair sequence

1. Connect a production general research driver and its continuation conformance to the capability executor. The new host path currently has a prepared controlled executor, not an ordinary production caller. Complete workflow routing must carry the original request and canonical owner throughout; it must not route “Paris” or a date through ordinary standalone planning.
2. Compile complete goal and answer semantics: required outcomes, associations, negation, dates/places, preferences and quantities. Exact source retention does not prove interpretation, and a typed question does not prove that the model asked the right question.
3. Plan and journal dynamic browser actions under the original root. Preserve stable effect identities and reconcile prior attempts before choosing new work. An answer or login redirect cannot authorize replaying an already attempted form submission or navigation.
4. Extend and qualify the complete question/control lifecycle, including Pause arriving before an answer Prompt, login during an unanswered question, provider popups, lost browser presentation and restart. Current local-control mapping applies after answer admission; it does not borrow an old browser for an unadmitted message. No automatic login-completion or resume is added.
5. Verify source-associated offers, cross-page accumulation, constraints, prices/fees/availability and safe public result links. Publish complete or explicitly partial answers from current evidence. A valid question reference, model stop or current DOM reading does not establish task completion.
6. After explicit permission, compile and execute the controlled composition cases, then qualify the retained travel/concert/movie scenarios through the actual installed phone, host, model and browser. Keep real-site tests and performance measurements deferred. The 8 GB and thermal targets remain unqualified.

Related checkpoints: [request admission](REQUEST_WIRE_ADMISSION_REVIEW.md), [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md), [scoped browser questions](BROWSER_GOAL_CLARIFICATION_REVIEW.md), [candidate binding](BROWSER_RESULT_CANDIDATES_REVIEW.md) and [explicit workflow driver](BROWSER_WORKFLOW_DRIVER_REVIEW.md).

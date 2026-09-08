# Plan search terms from the retained user request

Date: 2026-09-07. Parent source: 131b98d. This checkpoint implements the local search-query proposal and connects it to the retained research owner and shared model runtime. **It does not yet dispatch a search, select a provider, implement the complete research driver or enable default research routing.**

## First-principles finding

Following a result link can use an observed native destination. The first search has no such page evidence. Its query must come from the user's intended work, while the host retains control over the eventual search destination. A model-generated URL or an arbitrary rewritten instruction is not an adequate replacement for that boundary.

A search query is also a lossy selection of terms. Even a useful query will often omit a price cap, fee requirement, date interpretation or prohibition that must still constrain the final answer. Query planning must therefore preserve the full canonical goal separately and must not claim that copied terms prove semantic equivalence, sufficient coverage or task completion.

## Implemented source path

`ComputerUseBrowserSearchQuery` decodes a closed `terms` object against the owner's validated goal interpretation. Each term identifies a requirement and copies a verbatim substring from that requirement's user source. Only outcome and condition requirements may supply terms. Prohibitions, ordering instructions and unsupported requirements cannot be selected as query text.

The host resolves exact UTF-8 source offsets. Requirement indices must remain in source order, and successive terms within a fragment must use nonoverlapping successive occurrences. A single source occurrence cannot be copied repeatedly to invent additional occurrences. Unicode normalization, invented text, reordered fragments, invalid indices, duplicate/unknown fields, controls and leading/trailing whitespace are rejected. Internal whitespace and original Unicode bytes are retained. These are source-integrity checks; the interpretation's role assignments and the semantic usefulness of a selected phrase still require qualification.

There are at most 12 terms, each at most 256 Unicode scalars/1,024 UTF-8 bytes. The host joins them with single spaces and rejects a combined query over 2,048 bytes without truncating it. An empty terms array produces no query; it is not evidence that a website has no results or that the user's request is unsupported. Query identity binds both the complete goal revision and the exact interpretation/source ledger. Debug descriptions omit term text.

`ComputerUseLocalBrowserSearchPlanner` receives the complete canonical request, exact clarification answers, original clock/time zone and indexed source ledger. It receives no webpage, account state, browser URL, assistant history or executable tool. Its closed `browser_search_query_v1` response schema has no URL, provider, action or completion field. Website/source restrictions remain in the full goal for later provider and action selection.

The planner uses the existing 4,096-token context, 1,024-token output and 64-token framing reserve. It counts the actual complete request once and rejects nonpositive or over-budget input before completion. It does not trim the goal to fit. The request uses the existing authenticated loopback connection, deterministic sampling, disabled prompt caching and 30-second timeout. The shared response decoder rejects mismatched model identity, truncated/tool-calling responses and invalid result shapes.

`ComputerUseRuntimeBrowserSearchPlanner` and the runtime's search-proposal entry use the existing native model owner, resource admission, model-access lease, endpoint identity and cancellation cleanup. They introduce no independent worker. Invalid research dispositions are rejected before activation in the wrapper and before model-access admission in the runtime entry. No model was activated during this repair.

The retained owner exposes `planInitialSearch(using:)` through its existing serialized operation boundary. A current research interpretation is required; pending navigation, an unanswered question, Pause and retirement block it. If the task already owns a page, native observation checks authentication/control before inference without supplying page content to the query planner. A returned proposal must match both the captured goal and interpretation. An accepted answer requires re-interpretation, and late results cannot escape cancellation. Planning alone neither claims a browser nor opens a page.

## Prepared verification and actual checks

Seven new methods prepare:

- Exact Unicode/source offsets, original goal identity, redacted descriptions and an empty query distinct from completion.
- Invented, normalized, reordered, repeated, prohibited and malformed terms, including closed-schema and index checks.
- Exact 2,048-byte admission, rejection above that limit or the scalar limit, and distinct source occurrences for repeated text.
- Complete goal/clock/source context, identical counting/completion request bytes and the fixed request contract without browser/tool context.
- Zero/over-limit token counts, both cancellation boundaries, model identity, truncation, tool-call and invalid response rejection.
- Owner interpretation/question prerequisites, exact accepted answers, rejection of an old revision and rejection of a different interpretation of the same goal.
- Pause/retirement while the planner ignores cancellation temporarily, retained operation exclusion, late-result rejection and explicit handback before retry.

The [focused source inventory](browser-search-planning-inventory.json) selects **134** methods, including prior research/routing cases and four existing shared native-runtime cases. The default source inventory selects **828**, seven more than the parent. The new implementation and test files are registered in the Xcode target.

Four Swift files pass syntax-only parsing. Project syntax, both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, model inference, app launches, browser execution or computer-use activity ran.** No new prompt/model qualification is claimed. The installed app and runtime/model assets are unchanged.

## Remaining repair sequence

1. Implement journaled initial search dispatch under the original research root. Bind the chosen query and host-selected destination, retain the same action through interruption, and reconcile an attempted request before making another choice. A query proposal alone must not authorize dispatch.
2. Handle explicit handback before the first page exists. The current owner's populated-session handback reacquires and observes a document; a newly allocated blank session has no document yet. The dispatch integration needs a distinct native empty-session check together with durable/native proof that the first request never started. It must not waive authentication observation for an existing page or treat a failed/uncertain load as an untouched session.
3. Select a search provider or initial website consistently with the complete request, including source restrictions. Do not let the model substitute a URL or assume that sending every copied source fragment to a generic search engine is authorized or useful. Qualify query selection against real phrasing and relative date/location needs.
4. Implement the concrete research driver, further search/form/date/choice actions and the ordered ledger, then supply it from the default loader. Use the existing retained candidate-navigation/replanning boundary after login and do not replace the original goal with query text.
5. Verify source-associated offers, dates, availability, prices/fees, public links and complete answer predicates across pages. After explicit permission, compile and execute controlled owner/driver/runtime cases, then qualify travel, concert and movie scenarios. Performance and 8 GB/thermal qualification remain deferred.

Related checkpoints: [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md), [goal interpretation](BROWSER_GOAL_PROPOSAL_REVIEW.md), [question proposals](BROWSER_QUESTION_PROPOSAL_REVIEW.md) and [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md).

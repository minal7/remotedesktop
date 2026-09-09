# Native date clauses in search and text-field payloads

Source repair; execution pending. This follows [the source-message date clocks](BROWSER_ANSWER_DATE_CONTEXT_REVIEW.md) and [explicit date replacement](BROWSER_EXPLICIT_DATE_REPLACEMENT_REVIEW.md). No build, typecheck, assertion, app, browser, model or account-login execution occurred.

## First-principles finding

A correct internal date is insufficient if the app sends the original relative words to a website. A request made on September 9 saying `tomorrow` means September 10 under its recorded date context. Copying `tomorrow` into a search box on September 10 lets the provider reinterpret it as September 11. Likewise, copying only `2026-10-16` from `before 2026-10-16` discards the user's bound even though the copied bytes are authentic.

The payload must preserve the interpreted date predicate as well as its source. The model may choose a native value; it may not invent the date, remove a comparator or present an endpoint as the complete condition. This remains a proposed search criterion. It does not establish that a provider understands that syntax or that any returned offer meets the condition.

## Native date terms

The [search-query boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSearchPlanner.swift) now provides a catalogue derived from bound native day predicates. Exact dates render as `YYYY-MM-DD`; bounds retain `before`, `after`, `on or before` or `on or after`; inclusive ranges retain `from ... through ...`. A model selects a strict `{"date":"dateN"}` term. The host supplies the text, using the source turn's retained date context.

Each term records every source row's requirement identity, turn, UTF-8 offset and byte count. A date assembled from several source fragments occupies its complete source interval. Partial, repeated and reordered date selections are rejected. Mixed queries retain the existing 12-term and 2048-byte joined-query limits. Ordinary literal terms still copy exact source substrings and retain the previous query digest format. Queries containing native dates use a new digest that includes the native normalization and all source records.

The [scalar ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) identifies current date conditions, native date origins, date-answer rows and rows overlapping retained historical date clauses. Those rows cannot supply literal terms, even when the selected substring looks like an absolute date. Relabeling or merging a known date with other text therefore does not create a literal escape. An unresolved date has no native value; a malformed or uncompiled replacement withholds the date catalogue and existing task-purpose guards prevent new payload authority. Superseded dates cannot be selected as active terms.

Search context version 3 includes `date_terms` catalogue version 1: short IDs, emitted text, complete source indices and the indices forbidden as literal terms. Its response schema is `browser_search_query_v2`. The catalogue exposes no internal native date identities. Date-free goals retain their existing context/schema behavior.

## Form integration

The [form decoder](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) accepts the same native date selections for text, search and textarea controls. It rejects them for URL, telephone and email controls. Native date inputs still use their existing exact `normalized_values`; number controls do not accept date terms. Before/after/range predicates are never shortened to fit a native date input.

Complete source lists feed both reviewed field-intent checks and recorded form provenance. A date split across two requirements cannot satisfy a review that authorized only one of those sources. The edit contract emits the canonical native text through the existing replace-all/verification path. Existing observation, preservation, interruption, handoff and query authority checks remain in force.

[Form context](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) version 21 carries the catalogue alongside existing date replacements, criteria and preservation state. The [planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) uses schema `browser_form_plan_v17` when date context is present; retain-only plans keep their existing schema. Instructions distinguish literal text from native dates and explicitly leave provider format and field meaning unqualified.

## Authored verification, unrun

Nine new methods are registered:

- Six [search methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSearchPlannerTests.swift) specify source-clock exact dates/bounds/ranges; a split answer accepted across midnight; active versus retired or uncompiled replacement terms; historical relabeling and unresolved weekdays; malformed/hybrid/repeated/reordered values and mixed UTF-8 byte limits; and model catalogue/schema/private-identity boundaries. A movie title containing `Tomorrow` remains ordinary literal text.
- Three [form methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) specify submission of an accepted answer's native date through a text input; complete-source review and provenance across split answers; and intact bounds with incompatible control kinds rejected. Shared helpers preserve the existing native date-input cases. The submission fixture expects September 11 exactly once and no September 10 query after a September 10 `tomorrow` answer.

Seven changed Swift files pass parse-only checks. Default/focused source inventories select 1759 / 1076 methods, with nine additions and no removals. These are syntax and source-registration checks only. None of the date outputs, assertions, field callbacks, query receipts, model schema behavior or provider outcomes has been executed or qualified.

## Remaining work

An initial broad outcome fragment may contain a date that native compilation has never identified. This patch does not claim to recognize every date or ban title words such as `Tomorrow`. Complete semantic compilation, negation/conditional handling and source partitions remain open. Known but improperly merged date sources may need clarification or corrected interpretation before any part can supply text.

Canonical English date clauses are not provider adapters. Departure/return/event associations, localized date widgets, site-specific syntax, provider time zones, publication-relative result text and ambiguous local times still require separate evidence and handling. Source order also does not establish the semantic relationship between different criteria.

General corrections, longer conversations, direct steering, account/document recovery and durable process recovery remain open. Global navigation-source completion is still restricted. Alternate-model comparison and any authorized RTX 3080 adaptation require measured model failures and usable remote access; no SSH, model run, distillation or pruning occurred here. The [repair checklist](../../../TODO.md) remains active, and real-site travel/concert/movie/login-handoff qualification remains deferred until explicit permission.

# A fixed date reference for each accepted user message

Source repair; execution pending. This follows [historical date grouping](BROWSER_HISTORICAL_DATE_GROUP_REVIEW.md). No build, typecheck, assertion, app, browser, model or account-login execution occurred.

## First-principles finding

Relative dates depend on both the words and the time at which the message is interpreted. Retaining one task clock protects the original request from drifting during a long task. Applying that same clock to every later answer, however, can misinterpret a new `today` or `tomorrow`, especially across midnight or after manual sign-in.

The rule must preserve both meanings: an earlier message keeps its own reference, and a new answer receives a new reference that then also remains fixed. Neither reparsing nor another model call should advance an already accepted date.

## Native message clocks

The [goal input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) now contains a validated native `DateContext` for the original request and exposes a context for each source turn. Its existing root timestamp, time zone and root digest retain the same values. Each accepted clarification carries its own immutable reference milliseconds and the task's original time-zone identifier.

The [live clarification boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) reads the host clock once for answer acceptance. That instant is used for expiry, the issuance-order check and the new answer's date context. Invalid, non-finite, out-of-range or backwards-before-issuance clocks cannot consume the question. An invalid answer also leaves the question available. A duplicate answer cannot install a different clock after the first acceptance.

The answer digest now includes its date context. Goal ancestry compares the complete accepted turn prefix, so a later interpretation cannot silently substitute another timestamp for an earlier answer. This applies to every answer topic: an answer to a location question can contain additional date text, and that text still belongs to its own source turn. Such extra text does not gain authority to replace an earlier requirement.

The policy uses the host's acceptance instant, not an inferred phone composition time or an assumed remote time zone. Date questions explicitly say that relative words use the date the answer is received in the task's time zone. Their source captions show the earlier message's civil date reference and zone. Actual source bytes remain unchanged inside the existing visible scope markers. The existing display, answer-size and question-count limits remain enforced.

## Parsing, correction and model context

All [native date parsing](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now requires the source turn explicitly. Root requirements, retained historical requirements, introduced date groups, ordinary confirmations and explicit replacements therefore use their own retained references. `today`, `tomorrow`, before/after bounds and supported ranges use Gregorian calendar-day operations in that fixed zone; adding a day is not treated as adding 24 hours.

For example, a request's `tomorrow` at 23:58 on September 9 denotes September 10. An accepted `today` after midnight can confirm that same date. An accepted `tomorrow` after midnight denotes September 11 and remains a conflict until the user explicitly answers a replacement question. The original date and all other requirements remain in history. A replacement answer does not shift forward when the planner runs again on September 12.

Shared goal context version 4 includes `dateContext` on every accepted answer. The top-level timestamp and zone continue to describe only the original request. A request without answers retains context version 2. Goal, search, action, form, result and link instructions now distinguish the source references. Native form normalizations carry the date derived from the appropriate message through the existing source-bound form path.

A website's relative date remains a separate problem. Its publication time and time zone are not established by either the user's message clock or the reading timestamp. The existing [result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) still does not interpret page-authored `tomorrow` using a user-message clock.

## Authored verification, unrun

Seven new methods are registered:

- Six [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover a missing date answered across midnight and later source splitting; an identical relative phrase that needs explicit replacement; different phrases confirming the same day; exact dates, bounds and ranges across both daylight-saving transitions; invalid/rewound clocks and duplicate consumption; and a non-date answer containing additional date text, with model-context and private-identity checks.
- One [form method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) specifies the actual native date-input and query path: an answer received on September 10 saying `tomorrow` must normalize and submit September 11, retaining the exact answer source and the original root clock.

The existing same-clock date helper now injects its clock, avoiding dependence on the day the future suite runs. An older original-clock fixture was also corrected: it previously supplied contradictory date and price-parameter answers while expecting them to remain bound. It now uses compatible answers and advances the answer clock between them, so it checks preservation of the original date and amount without expecting contradictions to disappear.

Thirteen changed Swift files pass parse-only checks. Default/focused source inventories select 1750 / 1067 methods, with seven additions and no removals. These checks establish syntax and source registration only. No assertion, calendar result, native field callback, model decision or website outcome has been executed or qualified.

## Remaining work

The task time zone remains fixed; explicit changes of time zone, event/provider-local dates, dates tied to trip legs and ambiguous local times still need semantic compilation. This patch does not establish the accuracy of a device's wall clock or recover clarification state after process loss. A delayed message uses the documented receipt rule.

Textual search payloads still need a complete policy for expressing previously anchored relative dates to websites whose own date context may differ; date-input normalization alone does not qualify arbitrary search boxes. General correction of locations, quantities, budgets and source policies, longer conversations, direct steering and document/account recovery remain open. The [repair checklist](../../../TODO.md) remains active, and global navigation-source completion is still restricted.

Real-site travel/concert/movie and login-handoff qualification remains deferred until explicit permission. No alternative model, SSH work, distillation, pruning or installed-app replacement occurred here.

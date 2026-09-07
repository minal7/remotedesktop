# Compile explicit scalar requirements without losing unresolved meaning

Date: 2026-09-07. Parent source: `9d9dc48`. New no-effect component layered on the retained browser goal proposal. **No host-routing integration, browser result extraction or research completion is enabled by this change.**

## First-principles finding

A number is useful only with its comparison and unit. A price also needs currency, scope and fee treatment; a date needs calendar meaning and a fixed reference when it is relative. Comparing naked values can incorrectly accept a $500 offer for “under $500,” count three result cards as three tickets, compare a per-person price with a total budget, or move “tomorrow” when a task resumes after midnight.

The goal proposal preserves every source fragment, but its model-selected fields, relations and value hints do not establish their meaning. This compiler reads the complete original fragment for each eligible condition. It derives the supported value and comparator from that source, rejects a contradictory proposed relation, and retains every uncompiled requirement in an explicit ledger. It cannot establish associations or logic between separate fragments.

## Implemented semantics

`ComputerUseBrowserScalarRequirements` retains the full proposal and exactly one ordered ledger entry per requirement. An entry contains either a condition or an unresolved reason. A clarification/unsupported proposal produces no bound conditions. Outcomes, places, ordering, prohibitions, standalone fee clauses and other non-scalar requirements remain unresolved for the broader compiler. A bound scalar does not erase any of them.

The supported source grammar is intentionally limited:

| Family | Supported interpretation | Preserved limits |
| --- | --- | --- |
| Quantity | Decimal counts from 0 through 999 or words one through ten; exact, at least, at most, more than and fewer than | Units remain results, options, flights, concerts, movies or tickets. No conversion of seats/party size into result count. |
| Price | Explicit comparison followed by USD/EUR/GBP/CAD/AUD/JPY or a literal currency symbol and a nonnegative decimal amount | Fixed-point hundredths; at most two decimal places and nine whole-number digits. Comma grouping must be valid. No floating-point rounding, exchange rates or inferred currency. |
| Price scope | Optional `total`, `per person` or `per ticket`, followed by optional `including fees` or `excluding fees` in the same fragment | Unspecified scope/fees remain unspecified. The compiler does not associate a separate fee clause with a price or invent missing taxes. |
| Civil date | Exact Gregorian `YYYY-MM-DD`, today or tomorrow; optional on/for; before/after; on or before/after; from a date through a date | Real month/leap-day validation, explicit strict/inclusive endpoints, inclusive `through`, and no reversed ranges. No implicit time-of-day or departure/return/showtime association. |
| Relative date | Today/tomorrow in the input's retained time zone and original reference instant | Gregorian calendar day arithmetic from local start of day, not elapsed 86,400-second increments or a new clock read. |

Outer whitespace, one leading `and ` and one trailing sentence separator can be removed for matching. The remaining source must match the entire supported grammar. The parser does not strip negation, alternatives, conditions or extra instructions to salvage a convenient value. A weekday such as “next Friday” or an unspecified `between` range remains ambiguous; other unsupported wording remains unrecognized. Invalid numeric/calendar values and source/model comparator contradictions have distinct unresolved reasons.

Value hints do not supply arguments. The original source supplies the comparator even when the proposal relation is unspecified. An explicit proposal relation must agree with the source. This does not verify the model's assignment of roles, source boundaries or relationships: for example, separately labeling “not” and “under USD 500” still requires whole-goal negation analysis before anything can use the scalar.

Each bound condition ID includes the original input digest, requirement occurrence ID and compiled predicate. Task, reference clock, time zone, source occurrence and interpreted constraints cannot be silently substituted. Recompilation of the retained proposal reads no new clock and produces the same conditions. This component adds no persistence or restart recovery.

## Comparison is not result verification

Typed observations support three outcomes: satisfied, not satisfied or unverifiable. These are **pointwise scalar comparisons**, not evidence that an offer or task satisfies the request.

- Counts require a nonnegative value and the same unit.
- Prices require an exact amount and the same currency token. A literal `$` and `USD` are different; the compiler does not guess equivalence. Any explicitly requested price basis and fee treatment must match known observation qualifiers. Starting-at/estimated amounts, mismatched scopes or missing requested qualifiers are unverifiable.
- When the request leaves price basis/fees unspecified, the comparator checks only the explicit scalar predicate. A passing number cannot fill those missing requirements. A later semantic/result gate must decide whether scope and fee information suffice for the user's whole goal.
- Civil dates compare against the compiled endpoints. Mismatched observation kinds are unverifiable.

The observation type does not certify its caller's facts. A separate result compiler must bind facts to actual document text, the correct offer, its date/location/currency/quantity scope, and current availability. A price in a neighboring card or an advertisement cannot become evidence merely by constructing an observation. There is no browser action, model call, input injector, “all requirements passed” gate or completion result in this component.

Default ledger, condition, amount and civil-day descriptions omit their source/value contents. Explicit typed data remains available in memory to the future compiler. This does not add telemetry or claim that arbitrary nested reflection elsewhere is sanitized.

## Prepared verification and actual checks

Nine test methods are prepared for:

1. Complete ordered ledger retention, unresolved dispositions and bounded descriptions.
2. Exact/strict/inclusive quantity boundaries, distinct ticket/result units and invalid observations.
3. Fixed-point price boundaries, decimal precision and amount limits.
4. Currency symbols, basis/fee qualifiers, exact versus starting-at amounts and explicitly unspecified scope.
5. Fixed-clock relative dates across time zones and daylight-saving changes, including a case where adding 86,400 seconds would choose the wrong local day.
6. Gregorian leap-day validity and strict/inclusive date ranges.
7. Source-derived comparators, irrelevant value hints and contradictory model interpretations.
8. Negation, alternatives, extra instructions, unsupported numbers and ambiguous dates remaining unresolved.
9. Distinct source occurrences and task/clock identities, with stable recompilation.

The new Swift source and prepared tests are registered in the Xcode project; SwiftPM and `project.yml` already include their directories. The [focused inventory](browser-scalar-requirements-inventory.json) selects **232** methods and the default selects **754**. Both new Swift files pass syntax-only parsing. Project-file syntax, exact source inventories and whitespace checks pass. **No typechecking, assertions, test execution, model inference, build, app launch or computer-use activity ran.** These are prepared regressions, not passing runtime evidence; the installed app remains unchanged.

## Remaining repairs in order

1. Compile whole-goal relationships: required outcome and result count, origin/destination/location, date/time roles, fees and budget association, alternatives, negation, ordering, availability and sort preferences. Do not treat all locally bound scalars as a complete semantic plan. Broader wording, singular nouns and unsupported scalar forms must be interpreted or clarified while preserving source.
2. Add typed clarification that keeps the original browser root, exact goal, all unresolved requirements and the fixed clock across answers and login handoff. Resolve ambiguous dates/currencies/scopes explicitly where necessary. Proposed questions and role labels remain interpretations, not authorization.
3. Connect the retained goal and compiler to actual host routing and a dynamic browser driver. Bind route selection before effects, use the existing owned session and journals, and continue only remaining work after explicit handback. Successful individual stages cannot complete the research task.
4. Build source-associated candidate records from browser structure and visible facts. Establish provenance, distinguish offers and price qualifiers, check complete requirements and qualify public result links. Arithmetic success alone cannot certify an offer or availability.
5. Once later permission permits execution, typecheck/build and qualify compiler, driver, result and handoff behavior with independent controlled cases. Actual model compatibility and live travel/concert/movie tasks remain deferred; held-out cases remain unused. Performance qualification follows correctness repairs.

The whole-browser repair remains open. This is a partial scalar compiler with an explicit unresolved ledger, not general natural-language research support.

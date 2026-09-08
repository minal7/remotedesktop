# Separate navigation scope from answer sources and compose research

Parent: `47c7adc`. This checkpoint connects a partial source compiler and the retained research driver to the default loader in source. It does not qualify the current model, complete research answers or replace the installed app.

## First-principles findings

“Only report offers from this website” and “only visit this website” constrain different things. Applying an answer restriction to every navigation can block an auxiliary search or account provider. Letting auxiliary pages supply answers has the opposite fault: a search snippet naming an allowed website does not originate from that website. Navigation and evidence need separate policies, tied to the same complete goal revision.

Source coverage and copied model values are insufficient semantic proof. A model can misclassify an exclusion, omit a domain from its hints, split alternatives into separate clauses or label source restrictions as another field. This change validates concrete source references and set operations after model interpretation; it does not solve those interpretation errors. Changing models cannot fix a missing default route or an incorrectly conflated policy.

The earlier driver/planners existed but the default loader omitted research. This checkpoint composes them, so future builds can reach the research route. Routing to a driver that cannot assemble verified answers still does not establish task completion.

## Source implementation

The goal proposal contract is now version 4. It retains complete source coverage and adds `navigationSource` and `answerSource` fields. The existing `source` field represents unresolved source meaning. Prompt instructions distinguish exclusive allowed sets, exclusions, alternatives, conjunctive constraints and preferences, with every accepted clarification answer retained separately. These instructions require actual-model qualification.

`ComputerUseBrowserSourceRequirements` compiles each proposed source clause into independent navigation and answer-origin sets. Alternatives in one clause form one set; separate inclusion clauses intersect; exclusions accumulate. Empty effective sets, unreachable eligible documents, excessive sets, ambiguous scope, unsupported relations and invalid references remain unresolved. No partial set is used if a hinted reference fails. Unsupported task dispositions cannot select providers.

The supported concrete references are exact ASCII origins or domain names, with an omitted scheme interpreted as HTTPS. Explicit scheme and port remain part of identity. There is no implicit `www`, subdomain, brand or alias expansion. Paths, queries, fragments, credentials and unsupported spellings are rejected rather than discarded. Token-boundary checks also reject a hinted host copied from an email, longer hostname or path-restricted URL. These checks do not establish that every source mentioned by the user appeared in the model's hints. Preferences, conditional exceptions, brands, IDNs, aliases and paths need further compilation; they currently require clarification or retained intervention.

The host supplies an ordered, bounded provider catalog. Selection tries only providers permitted by the navigation policy. A conflict returns no plan, without adding an implicit provider exception. The configured default is `https://duckduckgo.com/` with query parameter `q`, leaving provider settings unchanged. DuckDuckGo documents this [query URL format](https://duckduckgo.com/duckduckgo-help-pages/settings/params). Its [search syntax documentation](https://duckduckgo.com/duckduckgo-help-pages/results/syntax) also describes cases where related results may appear despite operators; query syntax is therefore not source verification. Provider DOM behavior and real searches were not exercised.

An unresolved source clause can produce a host-authored `source` question through the existing retained owner and controller/session-bound answer transport. Source prohibitions and ordering preferences can supply this topic's scope; unrelated topics still cannot use them. The original root, clock and all user turns remain intact, and an answer requires a fresh complete interpretation. Conflicting original requirements are not silently deleted. Complex corrections may still remain unresolved after an answer.

`ComputerUseBrowserResearchSources` now binds the provider, navigation policy and independent answer policy in one identity. The owner retains the full plan beside a known native policy installation before checking for reentrant Pause. A changed answer-only policy cannot widen a resumed task under the same revision. Accepted goal revisions can select a new plan when no effect or question is pending.

Native candidate preparation uses the committed document URL to attach `unconfigured`, `permitted` or `excluded` answer-source status. Candidate and link-selection identities include the answer policy. An excluded auxiliary page can still provide links to navigate. The link planner sees only the status, not native URLs or policy identifiers. A separate native answer-source validator requires the exact policy, current goal and fresh page evidence; unconfigured or excluded batches fail. This is a necessary check for future answer assembly, not proof of the seller, offer, relevance, availability, price or public source link. The research driver still never returns a completed answer.

The default loader now constructs the goal, query, result and link planners and the concrete driver using the same verified native-text inputs and existing runtime owner. Provider construction occurs before model activation. No separate worker or model change was introduced. Native/explicit capability routing still precedes research, and accepted research cannot fall back to desktop execution after ownership or effects. The installed app remains unchanged.

## Prepared coverage and actual checks

Eight new source-registered methods cover distinct navigation/answer behavior, provider conflicts, set intersections/exclusions, cross-scope contradictions, ambiguous and unsupported sources, copied URL substrings, scoped questions and exact accepted answers, native document provenance despite page labels, driver continuation without repeating the initial search, immutable answer policy and Pause during native installation. Existing schema and link-context expectations were updated.

Thirteen changed Swift files passed syntax-only parsing. Xcode project registration, whitespace and source-inventory validation passed. The [focused inventory](browser-source-requirements-inventory.json) contains 224 methods and the default contains 907, eight more than the parent. These are source identifiers, not passing assertions.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** Only read-only provider documentation was consulted. Runtime/model assets, held-out sets, installed app and prior qualification evidence were untouched. No disposable build artifacts were created.

## Remaining work

1. Qualify the version 4 full-goal interpretation and source sets against complete natural-language constraints, including negation, alternatives, missing hints, conditional preferences, multiple sites and source clarification answers. Bind richer site/brand/path semantics without silently broadening them. Ordinary provider selection does not replace site-specific search entry and form actions.
2. Complete general form/date/location/choice interactions, ordered durable action recovery and verified cross-page offer/answer assembly. An origin match alone must never satisfy all result predicates.
3. Complete visible manual takeover and reconciliation when automated navigation encounters a blocked account redirect after its first request was attempted. The initial request cannot simply be replayed. Qualify popup/redirect/handback behavior through actual current host/phone controls.
4. When execution is authorized, typecheck/build and run the bounded native/model suites through the default composition before proposing live travel/concert/movie E2E. All current schema, planner, WebKit and source-compiler behavior remains unexecuted at this revision.
5. Keep the alternative-model and authorized RTX 3080 desktop route available for measured model failures. SSH connection details are still pending after the prior timeout. Distillation/pruning and 8 GB/thermal optimization remain later work; no remote training or Mac inference ran here.

Earlier evidence: [native source policy](BROWSER_SOURCE_POLICY_REVIEW.md), [link planning](BROWSER_LINK_PLANNER_REVIEW.md), [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md) and [login handback](BROWSER_LOGIN_HANDBACK_REVIEW.md).

# Enforce host-selected document sources in the native browser

Parent source: `1b597ff`. This checkpoint adds native source-policy enforcement and connects it to retained research planning. Natural-language source compilation, provider selection and default-loader composition are still unfinished. The installed app is unchanged.

## First-principles findings

The local link selector could choose an observed link, but neither a link label nor its grouping proves that the destination satisfies a source restriction. The native browser validated URL form and navigation ownership without a task-specific source policy. Consequently, an observed link or a redirect could lead elsewhere even if a planner's instructions said to honor the user's sources.

A source decision needs to remain fixed with its goal revision and action binding. Replacing it during dispatch must not authorize an already prepared action under a different policy. Login also needs different treatment: the person may need an account provider outside the research sources, but returning control cannot make that account page eligible research evidence.

WebKit separates action permission from decisions made after a response is known. A response-stage rejection alone cannot prove that no request was sent; this implementation also checks native dispatch and action requests. These are document-navigation checks, not a firewall for subresources, DNS, preconnections or all browser network activity. [Apple's navigation delegate documentation](https://developer.apple.com/documentation/webkit/wknavigationdelegate) describes the separate decision stages.

Newer WebKit also exposes a history decision for Instant Back, which may restore a suspended page without the usual loading callbacks. That path needs the same source decision. The [WebKit delegate header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h) describes this behavior; Apple's [Swift method reference](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview%28_%3Ashouldgoto%3Awilluseinstantback%3Acompletionhandler%3A%29) supplies the public signature. Their documentation is not qualification evidence for the installed WebKit version.

## Source implementation

`ComputerUseBrowserSourceOrigin` represents an exact scheme, canonical host and effective port. It does not perform suffix matching or silently add subdomains. DNS labels are validated, IPv6 spelling is normalized, and noncanonical numeric IPv4 spellings are rejected when they have not already been normalized by URL parsing. Credentials and malformed origins cannot be approved. Host aliases, IDNs, brand names, path restrictions and broader source semantics still need deliberate compilation and qualification.

`ComputerUseBrowserSourcePolicy` binds optional allowed origins and explicit exclusions to the complete goal revision and root. An empty allow-list permits no origin; an absent allow-list is an explicit host choice of unrestricted document origins. Exclusion wins over inclusion. Canonical sorted sets supply a stable policy digest. This type cannot infer the user's intended constraints from a model's field labels.

`ComputerUseBrowserResearchSources` selects a provider and its policy atomically. It rejects a provider endpoint outside that policy; it never silently adds the provider as an exception. The research planning protocol and local-model bridge now require this combined plan. The concrete driver retains it for the accepted revision, configures the owner before query/action planning and does not broaden it when mutable host configuration changes during Resume. A missing plan leaves the original task unresolved.

The owner accepts one immutable policy per goal revision. Pending navigation and unanswered questions block replacement. An accepted clarification revision may receive a new plan, while the original root and history remain intact. Selecting policy alone allocates no browser. The owner tracks whether a selected policy was installed into its captured session, so interrupted admission/installation can retain the actual session and retry installation instead of assuming it happened. Owner operations compare their expected installed policy with the native browser's policy.

The native browser installs policy against an exact session seal and expected prior digest while navigation/DOM work is idle. Task replacement and Stop clear the old task's policy. Native loads capture the policy, validate their destination before dispatch admission, and recheck both policy identity and destination after the durable callback. A callback cannot replace the policy and let the old load proceed.

Observed link and form-query targets include the current policy digest in their payload binding. Their destination and policy identity are checked before and after DOM validation. Initial-search request identity also includes its policy. Existing journals therefore retain their original scope, and receipt recovery remains historical evidence rather than permission to reissue an action. A blocked redirect still attempted its initial request; its operation ID cannot be replayed as though nothing happened.

Main-frame action and response delegates check active automation destinations. Final automated navigation receipts also require a permitted committed URL. The macOS 26+ Instant Back delegate applies the same policy to cached history restoration. Source failure produces retained user intervention in the driver, with specific guidance in host Resume handling. It does not produce a completed research answer.

Manual navigation and sign-in windows retain their existing user-control behavior. Authentication observation may inspect a manually reached page before a new proposal, including outside the research origins. Result reading, however, checks the actual current document source before and after observation and before inference. Evidence validation also checks the document source. The existing authentication check remains ahead of result inference; an outside non-authentication page cannot become research evidence merely because the person returned control. Returning to an allowed page preserves the original task and initial-search history.

## Prepared regression coverage

Nine new methods cover:

- Exact origin matching, default ports, subdomain/lookalike and credential rejection, exclusion precedence, empty versus unrestricted policy, canonical IPv6 and numeric IPv4 aliases.
- Provider/policy conflicts and initial-search identity changing with its policy while preserving the query destination.
- Rejection before native dispatch admission, policy replacement inside the effect callback, compare-and-install failure and retirement/session exclusion.
- Allowed and blocked multi-hop redirects, expected request counts, historical receipts and refusal to replay a blocked operation.
- Observed link and form-query bindings changing with policy and rejecting a stale target before a fresh permitted navigation.
- Driver retention of the complete request when the provider or selected link is outside scope, with no widening or repeated initial search on Resume.
- Pending-stage protection, immutable accepted revisions, policy advancement after an exact clarification answer and no browser allocation for policy selection alone.
- Cross-origin manual login under a policy allowing only the research origin: early handback stops at authentication, no result inference runs while paused, and return to allowed results preserves the original goal and initial search.
- Scripted history navigation to a previously visited outside page, including the newer history restoration path when WebKit uses it.

Existing driver/link fixtures now return explicit source plans and can supply a controlled outside destination. The cases use native loopback components when eventually run; model decisions remain controlled fixtures. No assertions ran.

## Checks actually performed

Ten changed Swift files passed syntax-only parsing. Three fixture scripts passed `node --check` in one temporary file, which was removed. Xcode project registration passed `plutil -lint`; the new production/test files have their target entries. Whitespace and source-inventory checks passed. The [focused inventory](browser-source-policy-inventory.json) selects 216 methods and the default selects 899, nine more than the parent. These are reviewed source identifiers, not passing tests.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live E2E ran.** Read-only Apple/WebKit documentation was consulted. Installed app, runtime/model assets, held-out sets and prior qualification evidence were untouched.

## Remaining repair sequence

1. Compile complete natural-language source requirements into the host plan. Distinguish result-source preferences from restrictions on navigation itself. A permitted search or account provider must not automatically become an eligible offer source. Resolve domains/aliases, exclusions, brands, paths, contradictions and ambiguous source requests without widening them from a partial model ledger. Add retained source clarification where needed.
2. Select a suitable provider or site entry point. A provider that conflicts with the task needs another valid strategy, not an implicit exception. General site search/form actions remain necessary for requests that cannot use the current fixed query-provider interface.
3. Compose the provider/source compiler, current local planners and concrete research driver in the default loader. The production loader still omits research; this checkpoint does not activate installed-app research.
4. Complete general date/location/choice/form actions and a durable ordered action ledger, then qualify semantic progress, offer association, availability, quantity, dates, prices/fees, public links and complete answers across pages. Source permission alone does not prove relevance or completion.
5. Complete the visible manual handoff/reconciliation path when an automated redirect is blocked on the way to a legitimate account provider. The prepared manual-login case does not establish that path: the blocked navigation has already attempted its initial request and cannot simply be replayed. Execute the current native redirect/history/login/ownership cases, including supported OS/WebKit versions and actual host/phone control. Verify new method signatures and concurrency with typechecking/builds once authorized. Source review cannot prove WebKit callback order, outgoing request counts, window behavior or model quality.
6. Keep real travel/concert/movie E2E paused pending explicit permission. Alternative-model qualification and the authorized desktop adaptation route remain available when justified; SSH access details are still pending. Performance and 8 GB/thermal work remain the later phase.

Dependencies: [local link planning](BROWSER_LINK_PLANNER_REVIEW.md), [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md), [browser admission](BROWSER_ADMISSION_REVIEW.md), [initial search](BROWSER_INITIAL_SEARCH_REVIEW.md), [binding recovery](BROWSER_BINDING_RECOVERY_REVIEW.md) and [login handback](BROWSER_LOGIN_HANDBACK_REVIEW.md).

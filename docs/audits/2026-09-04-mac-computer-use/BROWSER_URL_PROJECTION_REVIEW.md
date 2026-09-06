# Browser callback URLs: exact identity, limited display

Parent source: `8657c60`. This is a source repair with prepared regressions. No build, test execution, model inference, app launch, computer-use activity or provider login occurred. The user's execution pause remains in force; performance work remains deferred.

## First-principles problem

A URL serves different purposes. The browser needs the exact destination to navigate, distinguish pages, preserve session transitions and validate an action's document. The person choosing whether to hand control back needs website identity. The task's completion message needs a truthful navigation result. Publishing every component of the address is unnecessary for the latter two purposes.

The owned browser previously published the complete URL when starting navigation, when its URL observation changed, after user-controlled navigation and after AI navigation. Its terminal navigation reply included the committed URL, which then entered the host task ledger and wire reply. Ordinary Swift document descriptions also expanded the retained URL fields and caller-supplied identifiers. A later conversation could therefore reuse callback material from an earlier assistant reply.

A denylist of familiar parameter names cannot solve this: opaque values can occur under arbitrary query keys, in fragments or in path segments. This repair uses a fixed website projection rather than trying to infer whether a value is a secret.

## Source changes

`ComputerUseBrowserSite.displayName` validates an HTTP(S) URL and constructs its display string through `URLComponents`, retaining only scheme, host and port. Path, query, fragment and user information are absent. Invalid/absent locations produce the fixed `Website unavailable` text, never the input string. Embedded credentials remain invalid navigation inputs. Full hostnames are intentionally retained; this does not remove opaque material embedded in a hostname.

`ComputerUseOwnedBrowser.displayedSite` replaces `displayedURL` at every owned publication point. A nil URL observation and browser release clear the previous website label. The SwiftUI label identifies this as the website, and the existing status line still distinguishes an opening page from an opened page. This change does not replace the current loading-state behavior with a new committed-origin indicator.

`ComputerUseBrowserNavigationTask` reports `Opened the page in the AI browser. Website: …` (or the existing plural result). It no longer describes the projection as the current page URL. The terminal reply and its durable replay therefore use website identity without manufacturing a shareable result link.

`ComputerUseBrowserDocument` implements standard string and debug descriptions containing only projected website identity and fixed source provenance. Requested/committed URLs, task identifiers and operation identifiers are omitted from those descriptions. This is not protection against explicit field access or arbitrary reflection; the exact fields remain available internally.

Navigation requests, retained URL arrays, receipt equality, exact current-document checks and digest-based contracts are unchanged by the display projection. Two different pages on one website are still different documents. Search parameters still reach the requested resource.

## Fragment-aware response matching for manual handback

The review exposed a separate overly strict comparison: manual handback required the HTTP response URL to equal the browser's full document URL. Fragment identifiers are processed by the user agent separately from resource retrieval. The URI specification also excludes fragments when comparing retrieval targets. See [RFC 3986 section 3.5](https://www.rfc-editor.org/rfc/rfc3986#section-3.5) and [section 6.1](https://www.rfc-editor.org/rfc/rfc3986#section-6.1).

The source now removes only the fragment when matching the successful response to the observed page. Scheme, host, port, path and query still participate. This helper is used only in the existing manual navigation completion branch, which requires the same `WKNavigation`, current generation, a successful displayable HTTP response and closed AI action gate. It does not use the website display projection as an authorization check.

The resulting observation retains the full current URL, including its fragment. Explicit handback is still required; no AI navigation receipt is invented. Later URL changes still invalidate the exact retained document through the existing observation path. This does not add general adoption of hash-only navigation or History API transitions and does not prove account identity or login success. The actual WebKit callback ordering and fragment behavior remain unexecuted qualification items.

## Prepared regressions and source checks

Five browser methods and one production host/coordinator method are added:

1. Website projection omits opaque URL components, preserves ports/IPv6/ASCII internationalized host representation, rejects embedded credentials/non-web/relative/oversized URLs, and keeps standard document descriptions limited while retaining exact fields.
2. A held search request redirects to a callback containing path/query/fragment values. Every published website value remains limited, independent HTTP requests retain the query, exact receipt URLs survive and same-site forged document references fail validation. Closing clears the label.
3. Response matching excludes only fragments. Changed scheme, host, port, path, query and credential-bearing inputs fail; exact document equality still distinguishes fragments.
4. A controlled navigation while the AI gate is closed reaches a callback with opaque components. It remains unavailable for automation until explicit handback, keeps the exact URL afterward and adds no action receipt or repeated navigation. This fixture simulates a navigation transition, not a real login.
5. A callback HTTP failure produces no success receipt and exposes no opaque URL value in the website/error/detail projections.
6. The host manager and capability coordinator navigate a controlled redirect, emit website-only terminal text, persist it, and replay it from a reconstructed ledger without entering native/desktop planning or making another navigation request. Raw ledger and step-journal files are checked for fixture values.

The existing two-page interruption/replay method also asserts the plural website-only reply. The reviewed manifests contain **587 default host methods** and **24 focused methods**. The source inventory verifier and whitespace check pass. This records source identity, not compilation or executed assertions. See the [focused inventory](browser-url-projection-inventory.json).

## Remaining repairs and qualification

- Page text, page-rendered URLs, screenshots, accessibility attributes and generic MCP free-text/structured results have separate exposure paths. The current MCP sanitizer primarily redacts known input values and sensitive keys; this patch does not establish general URL redaction there. The bounded DOM form adapter does not explicitly serialize document URLs, but arbitrary field content remains page data.
- This patch does not scrub previously saved task replies, phone conversations or logs. Historical exposure needs a separate retention/migration decision; silently replacing their exact task identity would be incorrect.
- Public travel/event/movie result links need a dedicated reviewed representation that preserves a usable resource URL without treating authentication callbacks as shareable evidence. An origin label is insufficient as a source link.
- Search, date controls, result extraction, remaining-goal rebinding, account-state verification, popup authentication and same-document session changes remain open. Visible host/phone handoff and real provider workflows still require later explicit permission and a bounded execution plan.
- No performance, fan, 8 GB, installed-app or broad natural-language qualification is claimed.

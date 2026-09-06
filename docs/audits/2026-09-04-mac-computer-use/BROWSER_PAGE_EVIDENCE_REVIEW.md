# Browser page evidence for search-result verification

Parent source: `5f2d477`. Status: source infrastructure and prepared regressions only. No type checking, build, test execution, inference, app launch, computer use or real-website task ran. This does not qualify ticket searching or complete the browsing repair.

## First-principles gap

A successful TYPE, Return or navigation proves an action boundary. It does not prove which tickets are available, whether the date and location match, or which link supports an answer. The owned browser previously exposed text-form fields and navigation receipts but no page-result observation. A whole browsing executor therefore lacked a reusable source of document-bound result text and links.

The implementation adds that observation boundary without treating the read as completion. The next repair must consume it through a browser goal/planner/result contract; existing natural-language routing does not yet call it. The API is available through `ComputerUseHostTools.observeOwnedBrowserPage` and `validateOwnedBrowserPageEvidence`, backed by the existing owned browser. It neither creates a new browser nor changes the current model schema, planner prompt, navigation grammar or completion gate.

## Source implementation

The fixed isolated-world script has two new commands: read a page snapshot and validate an earlier snapshot. The read scans the current main document and accessible open shadow roots, collects bounded laid-out text fragments and HTTP(S) links, and retains DOM container grouping and link-to-text references. Grouping is structural evidence; it is not a semantic claim that a price and date belong to the same ticket. Identifiers refer to observation data, not executable element targets.

The projection excludes scripts, styles, hidden/inert/ARIA-hidden content, form values, editable drafts and unsupported embedded surfaces. It uses text-range layout rectangles to exclude unassigned light DOM and unused slot fallback while allowing text beneath `display:contents`. It does not read innerHTML, input values, cookies or frame documents and dispatches no events or navigation. Links resolve against the document base URL as data. Script destinations and embedded credentials are excluded from the link list.

The reader permits up to 10,000 traversed nodes, 256 text fragments, 128 links and 65,536 combined text/label/destination bytes. Individual fragments and labels are limited to 2,048 bytes; URLs to 8,192 bytes. Limits set `truncated`; rendered frames, canvas, SVG, objects and embeds set `omittedEmbeddedContent`. These flags never establish exhaustive website coverage, including when both are false. Closed shadow roots, CSS-generated content, media, virtualized/lazy content and occlusion remain outside this projection. Main-document authentication metadata is checked before collection and again on validation; authentication inside omitted frames still needs a separate capability.

The immutable host evidence carries the owned browser document, DOM document nonce and snapshot nonce. Only the browser can construct it. The surrounding browser call rechecks task ownership, document generation, URL, cancellation and presentation across WebKit's await. The script validates an observation by re-reading its projection and comparing it to the retained read, including text, grouping, link destinations and coverage flags. This catches CSSOM changes that do not generate ordinary DOM mutation records. Root replacement changes the document nonce; a newer read supersedes the prior snapshot. Validation proves the retained projection is still current at that read boundary, not that every page surface stayed unchanged or that a later effect is authorized.

Raw destinations remain host-side and may contain private query/fragment data. Standard evidence/snapshot descriptions include only website identity, counts and coverage flags. The new types are not wholesale model/controller payloads. A future source-link adapter must review selected URLs before publication; blindly stripping query parameters would also destroy legitimate travel/date/source identity.

The [CSSOM View draft's Range section](https://drafts.csswg.org/cssom-view/#extensions-to-the-range-interface) specifies layout-rectangle snapshots, and the [DOM Standard's TreeWalker section](https://dom.spec.whatwg.org/#interface-treewalker) defines tree filtering. These support the choice of APIs, not a claim of WebKit compatibility or visual completeness. Actual rendering and shadow/slot behavior remain unexecuted fixture expectations.

## Prepared verification

Six methods are added to the existing owned-browser test class:

1. Rendered result text, base-relative URLs, exact link/text association, excluded values and inactive script links; no input event or extra navigation.
2. Staleness after changed price/status text, changed destination, CSSOM visibility changes and root replacement; a fresh read can then validate.
3. Explicit truncation and embedded-content omission, open shadow text, assigned content, excluded unassigned/fallback text, and bounded output.
4. Closed-gate reads dispatch nothing; password/OTP pages publish no page evidence; loss of control during the WebKit await cannot publish its result.
5. A new read supersedes old evidence, retained form bindings survive page reads, and close invalidates evidence.
6. A controlled login sequence requires explicit handback, rejects early handback at a password form, reads only the post-login document, invalidates pre-login evidence and creates no automation-navigation receipt for the user's navigation.

The default source manifest selects **610** methods; the [focused inventory](browser-page-evidence-inventory.json) selects **81**. Source inventories, syntax-only parsing of the five changed Swift files, embedded JavaScript `node --check`, and whitespace checks pass. These are not builds or executed assertions. Historical manifests are unchanged.

## Required continuation toward the actual product

1. Integrate page evidence into a whole-browser goal executor and the local planner with a bounded, explicitly untrusted text projection. Keep raw URLs/values out of that projection. Observation alone must not authorize action or completion.
2. Add document-bound link activation and search submission receipts, date/location/select widgets and fresh target acquisition. Keep user-authored constraints separate from model proposals and webpage instructions.
3. Compile result requirements for every requested entity, date, location, availability and price/fees. Preserve associations and cite only selected, reviewed source URLs. Missing/omitted/truncated evidence must remain unresolved rather than becoming an exhaustive answer.
4. Preserve the complete original goal across navigation and login. Rebind remaining targets after explicit handback without discarding attempted, verified or uncertain effects; closing a login window is not account proof.
5. Compile and execute the prepared composition regressions only when authorized. Then qualify bounded natural-language travel/concert/movie scenarios after the user's explicit permission. The 8 GB and fan-load requirements remain separate, deferred qualification work.

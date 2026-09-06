# Bind semantic execution to the owned browser page

Parent source: `f5014eb`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles gap

The preceding page-reader repair created an observation API but had no executor consumer. The visual semantic executor continued to bind proposals and answers to screen/AX state only. A link destination can change while its label and every screenshot pixel remain identical. A reported screen fact can also belong to a field value or another surface rather than the owned document. A browser read must therefore participate in the actual proposal and result boundaries before it can support a browsing goal.

## Source integration

Ordinary semantic execution now acquires a snapshot of the frontmost owned browser before the routing request. Production still requires the actual foreground window; explicitly headless browser fixtures use the same document/ownership API. Other applications and tasks without an owned browser retain their prior routing path.

The executor revalidates that exact snapshot after the asynchronous proposal, before ordinary input, and before returning a terminal result. Page/presentation drift consumes the existing bounded planning-retry budget and starts with fresh evidence; it cannot reuse the stale route. Authentication errors reach the host's existing nonterminal user-control handoff. Cancellation and other ownership/transport failures remain errors rather than no-effect routing declines. Final screen/focus checks still run after the asynchronous browser check.

For typed answers and obstacles, the host now applies its existing task-bound evidence verifier independently to the DOM text as well as to focused OCR. Only adjacent text fragments in the same observed DOM container are joined for this internal verification projection. Raw link destinations and page text are not appended to the current model prompt. Existing model configuration, tool schema, exact task authority, raw action history, target checks and terminal prerequisite rules remain in place.

The complete host-selected output also requires page support. Checking only the model's quoted fragments would let a returned OCR line contain an additional unsupported extension, qualifier or heading. The selected source lines, including the early self-bound obstacle path, must each occur in a DOM container's normalized text. The displayed answer still comes from the existing fresh screen verifier; model-authored prose is not returned directly.

This makes the page reader an actual production execution dependency. It does not yet give the local model a richer page-planning input or implement a whole-browser goal compiler. A current snapshot is observation evidence, never a navigation/input receipt, account-success proof or exhaustive result predicate.

## Prepared regression coverage

Five methods are added:

1. Production semantic answers through a controlled WebKit document and a virtual screen: a matching support fact can complete; a different DOM value or a value found only inside an input cannot be reported from the screen alone. Inline fragments of the same paragraph remain usable.
2. A page changes only a link's destination while the router is pending. Identical virtual pixels cannot preserve the first proposal. The executor reads again, asks for a new proposal, and records only one requested TYPE. Raw destination queries do not enter the model's visible-text field.
3. A password page with unrelated virtual screen/AX text stops before the semantic proposal and before input, forwarding the typed authentication error to host handoff.
4. The browser loses control during final evidence validation. No answer is published and no second proposal is made; the fixture terminates at the existing retry bound.
5. Pure verification checks require DOM support for every returned OCR line, including an added phone extension, a host-added appointment qualifier and the early obstacle path.

The current default source inventory selects **615** methods. The [focused inventory](browser-planning-evidence-inventory.json) selects **88**, including page-reader, browser/text handoff and existing terminal-evidence regressions. Source inventories, syntax-only parsing of five changed Swift files and `git diff --check` pass. No assertions ran. The virtual screen tests still need OCR/WebKit when later executed; they are not model qualification or actual keyboard-delivery evidence.

## Remaining work

1. Add a bounded, explicitly untrusted browser planning projection and a whole-goal contract. The local model still receives the existing screen-text input. This repair does not expand accepted travel/concert/movie requests.
2. Implement document-bound navigation/link/search submission and date/location/select controls, including attempted/verified/uncertain receipts and post-login rebinding of remaining work.
3. Carry browser document/result authority through the separate approval continuation and durable recovery paths. This patch covers ordinary semantic planning/input/terminal execution; it does not redesign their approval receipts.
4. Replace narrow visible-answer eligibility with complete result requirements. DOM grouping does not prove which event a price belongs to. Truncated/embedded/closed-shadow/virtualized content, exhaustive comparisons, selected public source URLs and account state still need explicit contracts.
5. Define supported behavior for pages that cannot supply the DOM observation, including PDFs and other non-DOM surfaces, without using an ambiguous stale/failed read as permission to continue. The current reader remains bounded and can stop unsupported owned-page execution.
6. Compile and run the prepared host/browser/executor composition when authorized. Qualify actual natural-language behavior and later real-website scenarios only with the user's explicit permission. The 8 GB and fan-load requirements remain deferred and unproven.

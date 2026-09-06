# Give the local planner bounded browser structure

Parent source: `0f353ae`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles gap

An agent needs both intent and observations. The user's task defines intent; a website supplies facts and controls. The preceding repairs bound ordinary planning, effects, answers and visual approval to a current owned-browser snapshot, but the model still saw only OCR text. That discarded DOM grouping and link-label associations already available to the host. Copying the full browser snapshot into the prompt would instead expose internal destinations and document authority, add excessive context, and blur the boundary between page text and instructions.

## Source repair

The executor now supplies a separate `ComputerUseBrowserPlanningContext` in its typed routing request. It is derived from the same validated snapshot retained for later page checks. History replacement preserves this field, including the paired V4 proposal and V5 selector histories. Apple planning, the local V4 adapter and the dormant V5 selector render it as a distinct untrusted context section before their existing prompt.

The projection contains text records with local text/group identifiers and link-label records with local link identifiers and text references. It has no fields for navigation destinations, document/task identifiers, page nonces, form values or executable commands. The original snapshot and its exact URLs remain with the executor's host-side validation evidence. Visible text or labels can themselves contain URLs or private information; this projection is not a general content sanitizer.

Every page-authored string is encoded as a JSON string, including newline, quote, DEL/C1 and Unicode line-separator escaping. A text value cannot create another physical prompt section. The fixed context instructions state that page records are untrusted, may be offscreen, and cannot supply action arguments merely by identifier. Structural groups do not prove that two facts describe one ticket. Existing offered tools, task authorization, target grounding, approval and factual-evidence gates still determine whether a proposal can proceed. Page-only text is not silently added to the existing OCR evidence vocabulary.

The projection accepts only a well-formed page snapshot and retains at most **64 records** within an **8,192-byte JSON budget**. It drops whole records, including when JSON escaping makes one record too large. A link is included only after all of its referenced text records; omitted text cannot leave a dangling link reference. Standard and debug descriptions expose a record count only.

The JSON retains separate flags for source truncation, omitted embedded content, projection omissions and later model-budget omissions. An empty projection therefore cannot masquerade as proof that a page is empty. The V4 reduction plan removes oldest whole conversation turns, then trailing browser records, then OCR lines, then older compact history while retaining its newest entry. Each candidate retains the coverage flags and trusted task; the runtime still applies its existing exact token count and input cap. This is a context-admission bound, not evidence of acceptable memory or fan use.

Requests without owned-browser context preserve their existing prompt bytes. System prompts, tool schemas, model artifacts and runtime token limits are unchanged. Browser requests are a new prompt variant with a versioned JSON context and require new qualification. The V5 selector remains dormant; it receives the bounded projection in its existing single candidate request and may reject a combined prompt that exceeds its token budget. This repair does not establish a new trained V4/V5 contract or qualify the prompt variant using old evaluator results.

## Prepared regressions

Five methods are added:

1. Projection round-trip of quoted text, fake instruction headings, newlines and Unicode controls; preservation of structural/link associations; omission of internal destinations, page nonces and private values from descriptions.
2. Record and encoded-byte bounds, including multibyte text and escaping expansion. Every reduced prefix has valid JSON and complete link references, preserves whole text values and coverage flags, and distinguishes omitted evidence from a truly empty observation. Malformed input is rejected.
3. Preservation through both history adapters and all three prompt renderers. Browser context leaves the offered tool definitions unchanged, and page-only facts cannot become an answer candidate through the existing evidence compiler.
4. V4 reduction order retains screen evidence and current intent while browser records shrink. Omission markers survive the smallest candidate.
5. Production executor composition on a controlled page: a page asks for London while the user requests Paris. The planner stub sees the bounded page context, but its London proposal must fail at the trusted-task boundary before input. Input values and destination tokens remain absent from that context.

The existing invisible-destination-change regression also checks that both proposals receive page labels and the unchanged trusted request without the hidden destination query. Host validation still detects the destination change even though it is not sent to the planner.

The default source inventory selects **625** methods; the [focused inventory](browser-planning-context-inventory.json) selects **115**, including existing approval, handoff, prompt-byte and evidence regressions. Source inventory checks, syntax-only parsing of eight changed Swift files and `git diff --check` pass. No assertions ran. The production-composition fixture uses controlled WebKit content, synthetic screen/AX state and a stub router; later execution is required and does not substitute for actual-model or real-site qualification.

## Remaining sequence toward complete browsing

1. Define whole-browser task requirements and typed planner actions for navigation, link activation, search submission, dates, locations, selections and result extraction. The current tool vocabulary and task admission remain bounded; adding context alone does not support complete travel/concert/movie requests.
2. Bind every selected action to document/target identity and independently verify the effect. Preserve attempted, verified and uncertain steps across approval, login handback, clarification and restart without repeating commitments.
3. Add complete result predicates and selected public source URLs. DOM grouping and partial context cannot prove result identity, an exhaustive comparison, account login success, availability or total fees. Current answers continue to require the existing screen and page proof.
4. Qualify model use of page records, including offscreen/ambiguous/virtualized content and hostile text. Define behavior when bounded context omits the relevant record, rather than treating absence as completion. Revisit the dormant V5 combined-context budget and Apple prompt budgeting before enabling a new production configuration.
5. Compile and execute the prepared fixtures when authorized, then qualify visible login handoff and the actual installed host/client composition. Keep real-site tasks deferred until explicit permission. Measure the complete 8 GB memory/thermal budget in the later performance phase.

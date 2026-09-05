**Mac local-AI computer use: first-principles audit and repair design**

Reviewed September 4, 2026. Repository: [minal7/remotedesktop](https://github.com/minal7/remotedesktop). Pulled main into the current workspace at commit **603e79e9f877a4a1c9a0b462d8db4da06dc46cf2**. This report concerns the Mac computer-use implementation and its mobile control boundary. Windows internals and the separate model-training repositories were not audited.

**Main conclusion**

There is substantial, useful work here: explicit model/tool boundaries, pinned artifacts, typed actions, exact approvals, cancellation gates, and durable task claims. The limiting architecture is that a general user goal is repeatedly translated into a low-level operation, then checked against a growing collection of English phrase rules and special-case workflows. The application does not yet have a general representation of intended outcomes, completed steps, field-level edits, or evidence of progress.

A better model can improve action selection. It cannot repair missing state, wrong observation scope, lost typing, stale targets, or a verifier that cannot recognize the goal. Fix those foundations before adding another planner or expanding the prompt rules.

The review includes literal keyboard/text entry as well as the broader attempt to implement computer use. Findings marked **confirmed** follow directly from the reviewed code or a component probe. **Design risk** describes a supported failure mechanism that still needs live measurement. **Validation gap** means the necessary evidence is absent from this checkout or was not obtainable in this audit; it does not mean the feature is proven broken.

**The first principles**

Computer use is control of a changing, partially observed system. A screenshot is an observation of part of the state. A model output is a proposal. Posting an input event is an attempt. Completion requires evidence that the intended outcome exists.

For every step, the system needs to answer:

1. What user-authorized outcome is this step advancing?
2. Which application, document, window, and element own the target?
3. What must be true immediately before the action?
4. What precisely will change, and does it require approval?
5. What observation would prove the change succeeded, failed, or remains uncertain?
6. What can safely happen after interruption, timeout, or a crash?

Reliability compounds. As an illustration only, twenty independent steps with 95% success each yield about 35.8% task success; even 99% yields about 81.8%. Actual failures are correlated, but the lesson is the same: reduce unnecessary steps and verify outcomes. A parser accepting every action token says little about a twenty-step task.

The current path is approximately: mobile prompt → authenticated LAN broker → host manager → deterministic Mail/Calculator/app route or Apple MCP planner → visual fallback → typed semantic route → optional OS-Atlas point → host policy/approval → CGEvent → another observation. The shipped manifest is visual-only; the open-source semantic package is still dormant. [Composition][mcp-execute], [manifest][manifest], [visual loading][load].

The target design should be:

~~~mermaid
flowchart TD
    A[User request and authorized task context] --> B[Task contract: outcomes, constraints, budgets]
    B --> C[Observe scoped app, document, and elements]
    C --> D[Choose next unfinished step]
    D --> E[Compile a bounded action with preconditions]
    E --> F{Host policy and exact approval}
    F -->|Allowed| G[API or AX or browser action; visual input if needed]
    G --> H[Observe and verify the postcondition]
    H -->|Proven| I[Commit step evidence]
    I --> J{All requested outcomes proven?}
    J -->|No| C
    J -->|Yes| K[Complete with evidence]
    H -->|Failed or uncertain| L[Reconcile, retry safely, or ask for takeover]
    L --> C
~~~

This is a design proposal. Preserve host-owned authority throughout; do not give a model unrestricted shell access or remove existing safeguards to make benchmarks pass.

**What should survive the refactor**

- The model proposes typed actions; host code validates and executes them.
- MCP allowlists and exact-argument, one-use approvals, especially the embedded Mail path.
- Authenticated task transport, pinned data artifacts, signed execution code, and local inference.
- The injection gate, generation-scoped cancellation, held-input release, and special treatment of an approved effect that might already have happened.
- Conservative treatment of tool results and screen text as data, plus privacy-conscious diagnostics.
- Separate component, actual-model, and live product tests. Their different meanings should become clearer.

**Detailed findings**

Priority is implementation order: P0 means resolve before broadening capability or making general reliability claims; P1 means the next reliability/product increment; P2 means subsequent efficiency and maintainability work. These are not vulnerability severity ratings.

**F01 — P0 · A task needs an outcome contract and step state. Confirmed architectural gap.**

The visual loop retains action strings, counters, opened applications, and one recent semantic effect. It does not retain a general plan with named subgoals and completion predicates. Planning, policy, and completion independently reinterpret the same natural-language sentence. Each additional workflow therefore demands more coupled language rules. [Execution state and loop][new-loop], [deterministic routes][deterministic-routes].

Fix: introduce a runtime-neutral TaskContract with requested outcomes, entities, approved scope, constraints, and a bounded ordered/dependent step graph. Store per-step preconditions, attempts, observations, and verification status. A model may propose decompositions; the host validates scope and compiles supported capabilities.

Done when: a task spanning two fields and two submissions can be paused after any step and resumed using the same state, without a new English regex for that task. Unsupported outcomes must be reported before the app starts an unrelated partial workflow.

**F02 — P0 · The authority check also prevents legitimate planning. Confirmed.**

The policy requires many target words to occur in the current request, allows scrolling only when particular navigation words and directions occur, and requires text to be an exact phrase near a typing verb. “Find tomorrow’s forecast” may require scrolling and typing a query even though the user did not dictate those mechanics. “Write a short thank-you note” cannot generally authorize newly composed text through this GUI path. This is a deliberately narrow command executor, not general goal-directed computer use. [Semantic policy][semantic-policy], [payload binding][payload-policy].

Fix: authorize bounded capabilities against the TaskContract. Distinguish user-provided literal text, generated draft content, and externally sourced text. Draft generation can be allowed within a task while the exact outbound content still requires the appropriate final approval. Permit justified intermediate navigation within an authorized application/document.

Done when: held-out goal descriptions work without spelling out click, scroll direction, and exact keystrokes, while scope-expanding proposals are rejected.

**F03 — P0 · Repetition protection is keyed to the wrong thing. Confirmed.**

The typed policy rejects a payload if its TYPE history marker already exists, regardless of field. It rejects ENTER whenever any ENTER is already in history. The deterministic text route additionally stops after any TYPE. Two fields needing the same city, or a task requiring two searches, cannot reliably proceed. [Repeated-action policy][repeat-policy], [deterministic text][deterministic-text].

Fix: make idempotency identity task + step + target + operation + payload version. Repeating an operation in a new field or step is legitimate; retrying an uncertain attempt in the same step requires reconciliation.

Done when: identical text can fill two distinct fields and two searches can submit in one task, with no duplicate insertion or submission after retries.

**F04 — P0 · Pause/resume discards the workflow state. Confirmed.**

Pause saves the execution context and cancels the executor. Resume appends prose asking it not to repeat work, then begins execution again. The visual executor creates a new ExecutionState. The typed path continues to use the original trusted user request; appended resume prose is not a substitute for preserved progress. Approved visual continuations have stronger retention and must not be conflated with this ordinary pause path. [Pause][pause], [resume][resume], [fresh execution state][new-loop].

Fix: preserve the task graph and attempt ledger across pause. On resume, obtain fresh observations and reconcile each uncertain step. Discard old coordinates and approvals while retaining knowledge of attempted and verified effects.

Done when: pausing halfway through text entry, after navigation, and between two fields neither repeats prior work nor skips unfinished work. Restart recovery must clearly distinguish verified, unattempted, and uncertain actions.

**F05 — P0 · Typing records event emission, not text delivery. Confirmed.**

InputInjector emits Unicode key-down/up pairs per grapheme, which correctly avoids splitting emoji. Its Boolean reports whether the gate allowed the loop, not whether the application accepted the text. The executor records the effect and sleeps without reading back the field. The included probe compiles the real injector with a discard-only event sink and demonstrates that apply can return true with zero events delivered to macOS. [Injector][input], [perform][perform], [post-input bookkeeping][post-input], [probe][probe].

Fix: implement a TextEdit operation with target identity, insertion/replacement mode, expected initial state or selection, exact payload, and postcondition. Prefer a supported structured set-value/edit operation; use bounded Unicode input where necessary. Verify the resulting field or document state. Where secure input or an inaccessible control prevents verification, report uncertainty or hand control to the person.

Done when: dropped events, field validation, autocorrection, selection replacement, IME composition, emoji, and a mid-entry pause are detected and handled. “Posted” must never be presented as “verified.”

**F06 — P0 · Field identity is too weak for a durable edit. Confirmed design limitation.**

The Accessibility identity includes role, labels, identifier where available, PID, and rounded position/size. TYPE approvals intentionally exclude pixel checkpoints, and stable-focus revalidation excludes pixel changes when stronger authority exists. However, neither representation binds the current value/selection or a browser document/origin generation. A page can replace a field with another at the same geometry in the same browser process. Input also rechecks the action gate per grapheme, not the field identity. [AX identity][ax-identity], [approval target][typing-target], [focus fingerprint][focus-fingerprint], [injector][input].

Fix: bind edits to an observation-scoped element handle, document/window generation, browser origin where available, and appropriate field state. Re-resolve before execution and between bounded chunks; verify after execution. Do not store secret values in diagnostics or infer credential authority from a label.

Done when: same-location replacement, tab navigation, programmatic focus changes, and selection changes invalidate the edit instead of silently changing the destination.

**F07 — P1 · “Exact text” can be trimmed, and long text is not supported as comments suggest. Confirmed.**

The deterministic quoted-text extractor trims leading/trailing whitespace. Both it and the semantic executor apply a 512-character/2,048-byte validity rule. The wire-contract comment says long quoted payloads are handled by a deterministic route, but that route calls the same validator. This changes significant whitespace and rejects longer literals. [Quoted extraction][quoted-text], [text contract][text-contract], [route validation][route-validation].

Fix: retain exact user-authored payloads by reference; let the model select a payload ID instead of regenerating the content. Separate a model argument-size limit from the allowed size of a host-owned text edit. Chunk only at validated boundaries and preserve every intended character.

Done when: whitespace-sensitive snippets, leading/trailing newlines, quoted punctuation, and a 2,000-character literal arrive exactly, or are rejected before any partial input with a clear supported limit.

**F08 — P1 · Synchronous observation and input compete with UI responsiveness and takeover. Design risk.**

The executor and host tools use MainActor work for capture, repeated synchronous Vision requests, AX traversal, image processing, and native input. Double-click uses Thread.sleep; text entry runs a tight synchronous loop. Local intervention arrives through NSEvent monitors. Apple documents global monitor delivery as asynchronous; observing a physical action is not an instantaneous cancellation guarantee. The WebRTC injection gate already gives stronger synchronization and should be retained. [Capture][capture], [OCR][ocr], [perform][perform], [monitors][monitors], [Apple event-monitor documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)).

Fix: use dedicated observation and injection workers with explicit generation/ownership tokens. Keep main-thread work minimal. Use bounded, cancellable input sequences and a suitable event-monitor mechanism for timely local takeover. Measure cancellation latency under OCR, model loading, and text-entry load.

Done when: the agreed takeover latency is met at p95/p99 under load, no new automation effect starts after the gate closes, and held-input cleanup still works. This latency was not measured in this audit.

**F09 — P0 · The structured tooling is not being used as a general control substrate. Confirmed.**

The helper policy includes AX querying, value reading, notifications, and element actions, but the product planner exposes only seven read operations and embedded Mail. GUI tasks generally become screenshot/OCR/coordinate tasks. Even an exact OCR label is checked after a model grounding call. The current reviewed subset is reasonable for safety, but it creates a large reliability and latency ceiling. [Planner-visible tools][tools], [helper policy][mcp-policy], [grounding order][ground-point].

Fix: build a host-owned capability broker that uses reviewed application APIs first, AX element operations next, browser structure where appropriate, and pixels when those surfaces cannot express the action. Scope query results to the authorized document/window and avoid exposing arbitrary helper operations.

Done when: a standard native form can be filled, verified, and submitted through element handles with no vision inference; an inaccessible canvas still has a bounded visual fallback.

**F10 — P1 · Browser work lacks an owned document context. Confirmed limitation.**

The code correctly blocks helper browser operations after finding ambient Safari-window behavior and setup dependencies. The replacement is visual fallback, leaving no reliable tab/document ownership, DOM targeting, URL-based identity, or structured page-state verification. Unblocking the existing operations unchanged would undo a justified boundary. [Blocked browser tools][mcp-policy].

Fix: implement a browser adapter with explicit tab/window/document identity and narrowly scoped operations. Decide whether the product controls an existing user tab with consent or a task-owned context; account/session continuity is part of that decision. Use AX-only or visual fallback when a browser cannot supply the required structure.

Done when: two similar tabs are open, the foreground changes, and navigation occurs mid-step without causing an action in the wrong document. Routine setup should not require enabling unrestricted JavaScript from Apple Events.

**F11 — P1 · Observation is tied to the main display and duplicates capture infrastructure. Confirmed.**

AI currentScreen uses CGMainDisplayID and CGDisplayCreateImage, while streaming uses ScreenCaptureKit. A focused window on another display cannot be observed coherently through that path. There is no observation ID or timestamp in ComputerUseScreenObservation linking the AI frame to the streamed frame. The installed SDK marks CGDisplayCreateImage deprecated/obsoleted; Apple's preferred capture APIs are in ScreenCaptureKit. [AI capture][capture], [stream capture][stream], [Apple capture API](https://developer.apple.com/documentation/coregraphics/cgdisplaycreateimage), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).

Fix: introduce one observation service with display ID, frame time, coordinate transforms, window/document identity, and generation. Use ScreenCaptureKit with a chosen target display/window. Either support multiple displays correctly or expose a clear single-display restriction and reject incompatible tasks.

Done when: Retina scaling, negative monitor origins, a moved window, display disconnects, and a target on a second screen all produce correct coordinates or a deliberate no-action result.

**F12 — P1 · The visual model receives too little spatial information for many desktop controls. Confirmed configuration; accuracy impact needs measurement.**

The entire display is reduced to at most 448 pixels on its longest edge. A 3,840-pixel-wide desktop becomes 448 pixels wide; a 24-pixel-high glyph is only about 2.8 pixels high after that reduction. OCR uses the original frame, but the grounder loses visual detail before inference. Upstream OS-Atlas examples support dynamic image preprocessing; the current low-memory restriction is a tradeoff, not evidence that 448 is sufficient. [Image limit][vision-limit], [JPEG resize][jpeg], [upstream model card](https://huggingface.co/OS-Copilot/OS-Atlas-Pro-4B).

Fix: use a scoped overview plus target crops or an adaptive resolution budget, with explicit crop-to-display transforms. Prefer structural grounding when present. Benchmark tiny icons, dense tables, and duplicated labels.

Done when: target accuracy is measured by size and display scale, and extra image cost is justified by task success. Do not simply raise the pixel limit without validating the runtime's image-token and memory limits.

**F13 — P0 · The model's observation scope and the freshness check disagree. Confirmed.**

Semantic routing reads full-display OCR, and visual grounding sees the full display. Freshness hashing normally crops to the focused window. A background window can therefore contribute labels or apparent results without being included in the checked image region. Some terminal paths correctly use focused OCR, but that does not make the earlier routing observation coherent. Existing target checks reduce the risk; this is not a demonstrated end-to-end bypass. [Routing OCR][routing-ocr], [fingerprint crop][fingerprint], [focused terminal OCR][focused-ocr], [grounding][ground-point].

Fix: use the same authorized observation scope for planning, grounding, freshness, and verification. Keep background content out unless the task explicitly authorizes that surface. Tag every derived OCR/AX datum with its source observation and region.

Done when: changing a background page cannot influence a focused task; any intentionally observed region is also included in freshness and provenance checks.

**F14 — P1 · Exact image hashes are a brittle definition of “same state.” Design risk.**

The planner compares SHA-256 over a downsampled 256×256 focused image. A caret, hover state, animation, or loading indicator can change it and force replanning; a semantically significant tiny change can also disappear in the downsample. The code already adds exemptions for typing, app opening, pending waits, and some answers, demonstrating the mismatch between pixel equality and action validity. [Fingerprint][fingerprint], [exceptions][focus-fingerprint].

Fix: define operation-specific preconditions: stable target handle, enabled state, document generation, target-local geometry, and selected content as appropriate. Use image comparison as supporting evidence, not a universal state definition. Use event-driven stabilization plus bounded polling.

Done when: an unrelated animation does not starve a valid click, while movement, replacement, or changed meaning of that target does invalidate it.

**F15 — P1 · OCR is treated as stronger evidence than it is. Confirmed implementation; error rates unmeasured.**

The implementation takes the top OCR candidate, applies language correction, and often discards confidence and geometry when converting to text lines. Several paths set minimumTextHeight to 0.012 of the image. Quote extraction is explicitly en-US. Exact matching against OCR can prove agreement with the OCR output; it cannot prove the pixels were read correctly. [OCR][ocr], [OCR grounding][ocr-ground], [quote extraction][quote].

Fix: retain bounding boxes, confidence, source frame, and raw versus normalized values. Prefer AX/DOM values where available. Use task-relevant crops and explicit locale/number/currency handling. Require cross-checks for consequential numeric facts.

Done when: small fonts, ambiguous digits, decimals, currencies, localization, and duplicate labels are evaluated; low-confidence evidence causes another observation or uncertainty rather than a confident wrong answer.

**F16 — P0 · Completion checks are useful special cases, not a general success model. Confirmed.**

There are good host-derived Mail/read projections and fresh post-effect checks. Generic GUI completion, however, is built from deterministic phrase recognizers and a recent effect. The system cannot generally establish that every part of an arbitrary compound task is finished. Action history proves an attempted sequence, while a success phrase proves only a visible phrase unless tied to the intended object and operation. [Completion predicates][completion], [effect verification][effect-answer], [structured answer projection][mcp-answer].

Fix: attach outcome predicates to the task graph and verifiers to each capability. Use object IDs or typed app state where possible; otherwise require scoped visual evidence of the exact requested change. Represent uncertain outcome explicitly.

Done when: a stale success banner, an unrelated “done” message, or completing only one of two requested changes cannot finish the task. Legitimate completion must not require a particular English phrase.

**F17 — P1 · Fixed sleeps and counters substitute for progress detection. Confirmed.**

The visual path uses 700 ms after actions, one-second waits, 25 steps, five planning-state retries, and three consecutive recognized pending observations. WAIT consumes step count. These bounds are useful stop mechanisms but do not express a task deadline, meaningful progress, or an application-specific stabilization condition. Model HTTP calls can individually allow 120 seconds. [Loading defaults][load], [loop limits][limits], [wait handling][effect-loop], [HTTP timeout][runtime-timeout].

Fix: introduce monotonic task/stage deadlines, event-driven waits, progress predicates, repeated-state/action detection, and bounded recovery policies. Pause time and user approval time should have explicit budget rules.

Done when: slow loading succeeds within a configured task budget, a no-op loop stops with an actionable reason, and the UI shows what is pending rather than monotonically increasing step numbers.

**F18 — P0 · “Ready” does not mean generally capable local computer use. Confirmed.**

The current manifest is explicitly legacyVisualOnly. OS-Atlas is loaded and the Apple semantic router is installed, but its non-deterministic actions depend on Foundation Models availability. Setup can report ready without that model being available, because readiness mostly reflects helper/visual runtime state. Rechecking Apple availability on each route is good; it does not make an absent planner available. [Manifest][manifest], [Apple availability][apple-availability], [readiness][ready], [setup][setup].

Fix: publish a capability matrix rather than a single ready Boolean: native tools, deterministic commands, general language planning, visual grounding, supported languages, and transport reachability. Decide whether Apple Intelligence is an explicit requirement or ship a genuinely independent semantic planner.

Done when: a Mac with Apple Intelligence disabled is told its actual capability before a task starts, and the supported fallback is exercised from the same installed package end to end. Apple itself recommends availability checks and a fallback experience. [Apple availability guidance](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models).

**F19 — P1 · Apple prompt limits are byte limits, not context budgets. Confirmed.**

Requests permit a 32 KB task, substantial conversation and OCR, and large schema totals. The Apple path creates a fresh session per step with instructions plus every offered tool and sends that content without a tokenizer-aware reduction strategy. The dormant Granite adapter has an explicit counted budget/reduction plan; the shipped Apple path does not provide equivalent handling. [Request bounds][apple-limits], [visual request][apple-visual-request], [Apple sessions][apple-session], [visual session][apple-visual-session], [Granite budget][granite-budget].

Fix: budget the complete prompt including schemas and output. Select only relevant capabilities, summarize verified task state, reduce observations by relevance, and handle context overflow as a distinct recoverable error. Preserve exact user payloads outside model text.

Done when: maximum-size accepted requests, multi-turn context, and dense screens produce a valid budgeted request or a clear preflight rejection. Apple's documented on-device session context is 4,096 tokens, shared by instructions, prompts, and outputs. [Apple context-window guidance](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window).

**F20 — P1 · V5 adds a second model without solving candidate generation. Confirmed dormant design.**

The V5 proposer calls Apple's router and returns a one-element candidate array. Granite can accept that candidate or abstain; it cannot choose a better absent action. The current runtime alias remains semantic-router-v1/nativeRoutingV4 and the manifest contains neither semantic model. V5 therefore neither ships today nor removes the Apple planning dependency in its current proposed composition. [V5 proposer][v5-proposer], [composition][v5-composition], [served alias][model-alias].

Fix: explicitly choose what the second model is for: a verifier, independent planner, or selector over host-generated candidates. For a selector, measure candidate recall before selection accuracy. Test the incremental false-accept/false-reject rate, latency, and memory against a single-router baseline.

Done when: the second stage demonstrates a useful measured benefit on held-out tasks. Do not publish a model artifact solely to complete a diagram.

**F21 — P1 · Model choice and preprocessing need task-specific evidence. Validation gap.**

The manifest rationale chooses Pro because it generates actions, while production uses it only as a CLICK carrier for pointer grounding. Upstream distinguishes Base grounding checkpoints from Pro single-step action checkpoints. Neither fact establishes which is best for this app, this quantization, this prompt, and these crops. [Manifest rationale][manifest], [grounding prompt][ground-point], [upstream model roles](https://huggingface.co/OS-Copilot/OS-Atlas-Pro-4B).

Fix: compare the exact installed Pro configuration against an AX/OCR baseline and a suitable grounding-specific configuration. Include quantization, template, preprocessing, and action parsing in the evaluated artifact. Record misses before and after host OCR/AX correction.

Done when: the chosen model is justified by macOS task success and resource use, with raw model grounding separated from host correction. This audit does not establish that another checkpoint is superior.

**F22 — P1 · Setup couples lightweight capabilities to a multi-gigabyte visual dependency. Confirmed.**

Setup installs the helper, downloads/loads the visual model, composes the executor, then declares readiness. MCPFirst readiness requires the visual fallback. Thus a structured action such as opening an app or preparing a fully specified Mail operation is gated by the visual package and runtime. The three current model artifacts total approximately 3.052 billion bytes. [Setup][setup], [readiness][ready], [artifact sizes][manifest].

Fix: activate capabilities independently. Make reviewed structured tasks usable once their own prerequisites are ready; load vision on demand. Keep package activation atomic within each capability and retain all signature/hash checks.

Done when: a missing visual model does not prevent a supported structured task, while a task that needs vision explains and obtains that prerequisite without falsely advertising it as ready.

**F23 — P1 · Low-memory support is a resource policy, not yet field qualification. Validation gap.**

Compact mode has useful headroom checks and ceilings. The README says it was exercised on a 32 GiB Mac, not physical 8 GiB hardware. The future compact multi-model mode keeps one worker resident and explicitly switches between semantic and visual workers, which could impose repeated loading costs. Process limits also do not by themselves establish a good whole-device experience with Apple inference, WebRTC, browser content, and GPU memory. [Resource profiles][resource], [qualification limitations][readme].

Fix: test actual 8/16/32 GiB devices under realistic foreground workloads and thermal conditions. Measure aggregate memory pressure, swaps, cold/warm step latency, capture responsiveness, and cancellation. Define idle unload and pressure-driven capability degradation.

Done when: every advertised hardware tier passes the same task acceptance criteria, or the UI clearly restricts unqualified tiers. Measure future worker-switching costs before adopting that composition.

**F24 — P2 · Structured-to-visual fallback loses accumulated task evidence. Confirmed.**

Structured planning stores reviewed results in PlanningState. On planner failure or step exhaustion, executeVisualFallback receives the original prompt/conversation, not those results or the structured progress state. The same task may therefore repeat reads or lose a resolved entity. Current restrictions limit unapproved mutations, which reduces consequences but not wasted work. [Fallback boundary][mcp-execute], [structured state][mcp-loop].

Fix: use one capability-independent task context containing typed, provenance-tagged read results and verified progress. Pass only relevant, authorized evidence across backends; do not concatenate raw helper output into trusted instructions.

Done when: a contact lookup or other read can feed a later supported visual step without re-fetching or guessing, and switching backends preserves the same scope and step IDs.

**F25 — P0 · Consequential-action classification relies on English labels. Confirmed component behavior; no end-to-end exploit claim.**

The safety policy recognizes a finite keyword list and lets Return bypass approval when the context contains “search.” The probe shows Send requires approval while Enviar and Continue do not, and a synthetic “Search and submit payment” context bypasses the Return approval branch. Other task/target checks still apply. The problem is that UI wording is neither a complete nor stable description of an effect. [Policy][safety], [probe][probe].

Fix: attach effect classifications to reviewed capabilities and known application/document states. Treat labels as evidence, not final authority. Require exact approval at an external/consequential commit boundary; treat unclassified commit-capable behavior conservatively. Preserve a smooth path for clearly scoped harmless navigation.

Done when: localized labels, icon-only buttons, ambiguous Continue buttons, deceptive “search” context, and keyboard submissions are classified consistently by consequence. Measure approval frequency as well as missed approvals.

**F26 — P1 · Task-level at-most-once execution does not provide action-level recovery. Confirmed limitation.**

The task ledger stores claim, execution-started, control revision, and terminal result; it is not a full GUI step journal. The code has separate mutation protections and special handling for uncertain approved effects, which should survive. But an ordinary partially typed GUI action followed by pause/crash is not generally reconciled from durable field/step evidence. [Task record][ledger], [input bookkeeping][post-input], [pause][pause].

Fix: journal action identity and state transitions before consequential attempts and after verification. Use unattempted / attempted / verified / uncertain states. On restart, reconcile observable state; do not promise exactly-once effects for an external application that offers no transactional API.

Done when: crash injection before posting, during input, after posting, and before result delivery either restores a verified checkpoint or presents an honest uncertain outcome without automatic duplicate effects.

**F27 — P1 · Local inference and local-network reachability are conflated at the product boundary. Confirmed limitation.**

The broker deliberately accepts only private local endpoints. There is no CloudKit task fallback, and the remote-desktop transport is STUN-only. Therefore a user may have the right account and a host capable of local AI but still be unable to submit a task from cellular or another network. This is a scope decision rather than an AI defect. [Broker][broker], [transport description][readme].

Fix: choose and communicate the product promise. For same-LAN computer use, show reachability separately from model readiness. For remote use, add an authenticated encrypted task path over an existing secure peer channel, VPN, or appropriately designed relay without silently moving inference or private task contents into CloudKit.

Done when: same-LAN, cellular, restrictive NAT, VPN, disconnect, and reconnect behavior matches the stated product scope. Account enrollment must not be displayed as proof of a reachable task channel.

**F28 — P0 · Component coverage does not prove end-to-end task competence. Validation gap.**

The tests cover many important parser, policy, transport, and executor boundaries. Some actual-model tests use hidden rendered screens and intercepted actions; regular-user matrices with Apple unavailable exercise the supported deterministic subset. The repository explicitly leaves signed Release enrollment → prompt → local inference → approval → result acceptance pending. Those facts cannot support an unrestricted “computer use works” claim. [Actual matrix][actual-matrix], [pending acceptance][pending-acceptance], [test documentation][readme].

Fix: keep unit/component tests, add production-package model tests, and maintain a separate held-out live task benchmark. Never count a safe abstention as a successful completion of a supported task. Record intervention, false completion, unauthorized effect, and cancellation failures separately.

Done when: the exact candidate release runs the complete mobile-to-Mac flow and achieves declared task-level acceptance targets across real app states and hardware. No private real-world send or purchase is needed for the general benchmark; use controlled fixtures and sandboxed effects.

**F29 — P0 · The acceptance runner currently encodes stale expectations and an unshipped package gate. Confirmed.**

The deterministic runner requires exactly 138 passing tests. Source inspection finds 154 methods in the selected executor suite plus 13 explicit method selections, totaling 167. Its verifier compares exact counts. The Python contract test asserts the stale literal 138 instead of validating the selected inventory. Separately, actual-model acceptance begins with a V5 gate requiring semantic-router-v2/candidateSelectionV5, while the current alias is V4 and the production manifest is visual-only. Thus the current package cannot satisfy that gate even if its shipped paths work. [Expected count][runner-count], [selection][runner-select], [strict verifier][runner-check], [stale Python assertion][stale-test], [V5 gate][actual-v5-test], [alias][model-alias].

Fix: derive or explicitly review the expected test identifiers from discovery, and compare identifiers plus outcomes rather than a hand-maintained total alone. Split current-package acceptance from future-package qualification; label the latter as unmet prerequisites.

Done when: a passing current deterministic suite passes its runner, adding/removing a test creates a meaningful inventory review, and current Release acceptance does not depend on an unpublished model package.

**F30 — P0 · Normal PR validation does not execute the Mac Swift suite. Confirmed; local blocker reproduced.**

The Apple PR job runs Python harness tests and iOS tests. Mac XCTest is deferred to the signed Release workflow. In this audit the targeted Mac test build stopped before test execution because no matching development provisioning profile was available. This leaves routine changes to the most complex Mac logic with weaker feedback than the release gate. [Validation workflow][ci].

Fix: extract policy, task state, schemas, routing contracts, and parsers into modules testable without the signed privileged host or model bundle. Keep a signed integration job for TCC, runtime trust, and native actions. Preserve real release signing checks rather than weakening them to make unit tests runnable.

Done when: every PR executes the Mac core tests without distribution secrets, and candidate releases run the privileged integration gates. The environment's profile error is not evidence of a Swift compiler failure.

**F31 — P2 · Concentrated policy code and limited diagnostic structure make failures expensive to understand. Confirmed structure; operational impact inferred.**

The planner file is 6,058 lines, host manager 6,041, visual executor 7,987, and structured executor 2,538. These four files alone contain 22,624 lines spanning app identity, language parsing, task rules, approvals, OCR, lifecycle, and execution. Logging wisely avoids private text, but many failures collapse to broad generation/unsupported/unable categories. New phrase-specific tests can preserve inconsistent assumptions, as F29 demonstrates. [Planner][deterministic-routes], [manager][capture], [executor][semantic-policy], [privacy-conscious telemetry][telemetry].

Fix: extract cohesive components behind existing seams: TaskEngine, ObservationService, CapabilityRegistry, AuthorityPolicy, TextEditor, Verifiers, RuntimeManager, and transport adapters. Add bounded structured trace records with task/step/observation IDs, stage durations, policy reason codes, attempt status, model/artifact identity, and verification outcome. Raw screenshots or personal text should be opt-in local diagnostics with controlled retention.

Done when: a failed task can be classified as perception, planning, authorization, execution, verification, resource, or transport failure without reading private content, and a new workflow uses capabilities rather than adding branches across four files.

**A concrete typing design**

Treat typing as an edit to a particular object, not a string sent to whichever app currently has the caret.

A TextEdit record should contain: task ID; step ID; observation ID; application and document generation; element reference; insert/replace/append mode; exact host-owned payload reference; expected selection or initial value fingerprint where appropriate; maximum length; and a verification rule.

Resolve the element from fresh AX/DOM state. Validate focus, editability, document identity, and field constraints. If a structured setter/edit operation is supported and semantically appropriate, use it and ensure the application receives its normal change/validation semantics. Otherwise use bounded Unicode events and verify the resulting state. A clipboard path may be an optional explicit strategy, but must account for all pasteboard types, ownership changes, restoration races, and private content; do not make global clipboard replacement the default fix.

Store outcome as verified, rejected, or uncertain. A retry is allowed only after inspecting current field state. If half the string arrived, the next action must reconcile that exact field and selection; blindly typing the entire string again is incorrect. Keep user takeover and input-release behavior across all strategies.

For text generated by AI, compile the draft separately from the edit. For user-provided exact text, the model should carry a payload ID. Before an external send or submission, present the exact content and destination through the existing approval machinery.

**Implementation sequence**

The companion checklist maps every finding to an ordered implementation phase and explicit acceptance tests. The first useful vertical slice is one ordinary multi-field workflow, under real macOS input semantics, with two identical field values, two submissions, a mid-typing interruption, and independently verified final state. That single slice exercises the state, typing, observation, approval, and recovery foundations far better than another broad list of action tokens.

Do not begin by rewriting the entire application. Introduce the task/observation/verification interfaces behind the existing executor seams, move one path through them, and preserve existing approval and transport regression tests.

**Verification performed and limits**

- Pulled the repository's main branch and recorded the exact commit above; no app implementation was edited or published.
- Read the production composition, semantic policies, native input, AX identity, observation/OCR/grounding, approval/resume, task ledger, setup/resource management, local transport boundary, test suites, and acceptance/CI scripts. This is a focused architecture audit, not a claim to have exhaustively audited every line of the repository.
- Ran the existing Python harness suite: **102 tests passed**.
- Attempted seven targeted Mac XCTest suites using a separate temporary DerivedData directory. Build stopped with missing provisioning profile; **no selected Swift tests ran**.
- Compiled the isolated policy/input probe from real source files, with every input event intercepted. Its output and exact commands are recorded in VERIFICATION.md. The probe checks component semantics; it does not simulate the full authorization pipeline.
- Independently counted the runner's selected methods: **167 versus the configured 138**. This is source-derived inventory, not an executed XCTest count.
- Checked Apple documentation for model context/availability, event monitoring, and capture APIs, plus the upstream OS-Atlas model card. Recommendations about alternative models are hypotheses to evaluate, not performance claims.
- Did not download model weights, run an actual-model session, post input to the user's desktop, change TCC, send Mail, or execute a purchase. Live task success, latency, model accuracy, and physical 8 GiB behavior remain unmeasured here.

[manifest]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift:88>
[load]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:1075>
[semantic-policy]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:3932>
[repeat-policy]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:4001>
[payload-policy]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:4665>
[route-validation]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:3870>
[text-contract]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/SemanticNativeToolWireContract.swift:157>
[quoted-text]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:4722>
[deterministic-text]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:3723>
[pause]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:4384>
[resume]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:4419>
[new-loop]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:1440>
[input]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/InputInjector.swift:237>
[perform]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:2618>
[post-input]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2623>
[ax-identity]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:2435>
[typing-target]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:1967>
[focus-fingerprint]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:770>
[monitors]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:6013>
[capture]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:1273>
[stream]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ScreenCapture.swift:80>
[fingerprint]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:1332>
[tools]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift:216>
[mcp-policy]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPToolSafetyPolicy.swift:12>
[mcp-execute]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift:353>
[mcp-loop]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift:635>
[mcp-answer]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift:1397>
[ground-point]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2838>
[ocr-ground]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2899>
[vision-limit]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasLlamaRuntime.swift:600>
[jpeg]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:6623>
[routing-ocr]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2007>
[ocr]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:7000>
[focused-ocr]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:7036>
[quote]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:7357>
[completion]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:1281>
[effect-answer]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:3218>
[effect-loop]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2444>
[limits]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:875>
[apple-limits]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:20>
[apple-visual-request]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:179>
[apple-session]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:5088>
[apple-visual-session]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:5199>
[apple-availability]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:99>
[granite-budget]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/LlamaSemanticActionRouter.swift:7>
[v5-proposer]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/SemanticCandidateSelectionV5.swift:862>
[v5-composition]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:1202>
[model-alias]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasLlamaRuntime.swift:73>
[setup]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift:4826>
[ready]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift:252>
[resource]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasLlamaRuntime.swift:240>
[runtime-timeout]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasLlamaRuntime.swift:1987>
[safety]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/ComputerUseActionSafetyPolicy.swift:1>
[ledger]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskLedger.swift:62>
[broker]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/LocalComputerUseBrokerServer.swift:130>
[pending-acceptance]: </Users/michael/Documents/ChatGPT/remote desktop/PROGRESS.md:162>
[actual-v5-test]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests.swift:12225>
[actual-matrix]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests.swift:12762>
[runner-count]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/scripts/run_osatlas_acceptance.sh:10>
[runner-select]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/scripts/run_osatlas_acceptance.sh:143>
[runner-check]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/scripts/verify_xcresult_counts.sh:47>
[stale-test]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/scripts/tests/test_run_osatlas_acceptance_contract.py:73>
[ci]: </Users/michael/Documents/ChatGPT/remote desktop/.github/workflows/validation.yml:1>
[readme]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/README.md:1>
[telemetry]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/OSAtlasComputerUseExecutor.swift:2401>
[deterministic-routes]: </Users/michael/Documents/ChatGPT/remote desktop/host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift:829>
[probe]: </Users/michael/Documents/ChatGPT/remote desktop/docs/audits/2026-09-04-mac-computer-use/policy-probe.swift:1>

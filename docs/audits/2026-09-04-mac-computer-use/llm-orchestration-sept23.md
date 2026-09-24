# Local computer-use orchestration — September 23, 2026

Status: research and implementation design, not a qualification or production-readiness claim. Browser work is the first implementation milestone; native macOS work should reuse the same delegation/result contract later. Multiple local models are allowed initially, with one active inference operation at a time. Consolidation follows working workflows.

## Primary-source basis

1. [OpenAI Agents SDK: agent orchestration](https://openai.github.io/openai-agents-python/multi_agent/) describes a manager that retains the conversation and final answer while calling specialists as tools. This fits bounded delegation better than handing away ownership of the conversation.
2. [Microsoft Fara paper, sections 2.2–2.3](https://www.microsoft.com/en-us/research/wp-content/uploads/2025/11/Fara-7B-An-Efficient-Agentic-Model-for-Computer-Use.pdf) describes an Orchestrator directing WebSurfer, reviewing observations and updating progress. It distinguishes information-answer evidence from action-trajectory verification and says completion flags need further verification. **This is Fara's training-data generation pipeline, not the shipped Fara inference contract or evidence that the local checkpoint implements an orchestrator.**
3. [Anthropic: computer use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool) describes returning action results, explicit errors and fresh observations to the model. It cautions that models can assume an action succeeded and that page content can inject instructions.
4. [OpenAI Agents SDK: human-in-the-loop](https://openai.github.io/openai-agents-python/human_in_the_loop/) keeps nested interruptions within the original run and resumes retained state. It also distinguishes serialized state from authenticated ownership and requires reconciliation before retrying side effects.

These sources support the pattern. They do not qualify Apple's planner, Qwen, Fara or Holo for the proposed role, and adopting their SDKs or cloud services is not required.

## Current implementation versus planned change

The current app has an Apple structured MCP planner, a managed Qwen native-text browser step planner, and Fara/browser and Holo/native visual executors. Native tools execute effects. Browser proposals can already use native records, verified links, clarification and retained browser state.

At the baseline commit, `MCPProposalPlanningResult.browserTools` selected browser execution without a bounded subgoal/result contract. `MCPFirstComputerUseExecutor.executeVisualFallback` directly returned the specialist result. Browser completion therefore depended on local answer checks and language guards. Prior model classification/checking failures remain evidence against treating those models' labels as proof.

The first implementation adds an LLM assessment to browser planning and a bounded objective, constraints and completion criteria to visual handoffs. A specialist's terminal report returns to the browser orchestrator with the original goal and current observation. Scripted controlled tests verify this return boundary; actual model qualification remains open. This is not yet a general cross-application task graph: the top-level MCP route still selects the browser, and arbitrary effect receipts or pixel-only evidence cannot complete through the new native-record review contract.

Relevant existing files:

- `host-mac/RemoteDesktopHost/ComputerUse/AppleFoundationMCPPlanner.swift`
- `host-mac/RemoteDesktopHost/ComputerUse/MCPFirstComputerUseExecutor.swift`
- `host-mac/RemoteDesktopHost/ComputerUse/ComputerUseMCPBrowserStepPlanner.swift`
- `host-mac/RemoteDesktopHost/ComputerUse/ComputerUseFaraBrowserExecutor.swift`

## Three levels

| Level | Responsibility | Authority limit |
| --- | --- | --- |
| User intent / orchestrator | Interpret the full conversation, including typos, unconventional wording, conditions, prohibitions and clarification answers; delegate the next bounded subgoal; reconcile results and propose the final answer. | A model-generated plan, requirement list or completion label is fallible. It cannot grant approval or certify an effect. |
| Bounded specialist | Advance a browser or native subgoal using current observations and available capabilities. Return evidence, actual execution results, errors and unresolved work. | Completing its subgoal does not complete the full conversation. Native capability failures and planner failures are different; a planner failure does not establish a need for vision. |
| Deterministic action controller | Validate tool schemas, observed references, ownership, freshness, pending approval, cancellation, budgets and duplicate-dispatch protections; execute permitted effects and retain their actual results. | It enforces observable contracts, not natural-language meaning through intent keywords. |

The host retains the exact accepted user turns and their bound questions throughout delegation, clarification and Resume. A compact plan supplements that conversation; it never replaces it. Page text, tool output, specialist messages and orchestrator questions retain their provenance and cannot become user instructions.

A delegation needs a task/subgoal identity, natural-language objective, applicable constraints and a bounded execution budget. The original conversation remains available. Its result needs a status such as subgoal-completed, blocked or needs-user, plus source/observation references, executed-effect receipts, errors and remaining work. The current browser directive implements objective, constraints and completion criteria. Durable subgoal identity, general result statuses and an effect-receipt contract remain planned.

The intended orchestration runs on subgoal return, blockage or clarification. The first implementation still calls the browser tool planner at each observed step; persistent multi-step delegation is not implemented. Login/CAPTCHA handoff and action approval remain distinct. Resume continues the same owned task and rechecks the current state; it does not restart completed work.

Completion combines semantic review against the full conversation with available authoritative evidence. Reference validation establishes provenance, not entity association or full-goal satisfaction. Requested effects require their real receipts/postconditions; prose saying they happened is insufficient. Missing or uncertain evidence remains unresolved. An additional LLM verdict is not universal semantic proof.

## Sequential inference and lifecycle

`OSAtlasLlamaRuntime.shared` already owns managed llama processes. Its model-access lease and replacement lifecycle stop the old process and await exit before launching another; uncertain cleanup prevents subsequent launch. A cross-process lifetime lease covers the same executable path. Browser preparation resolves/activates the visual model lazily. Native text and trained visual launch profiles use the existing bounded worker budgets.

Apple `LanguageModelSession` calls are separate from those managed processes. The app does not control or measure Apple model residency through the llama memory cap. One managed worker is consequently not a claim that whole-Mac memory equals that worker's footprint.

The baseline had an integration gap: MCP planning used `ComputerUsePlanningWorker.shared`, while `ComputerUseFaraBrowserExecutor` owned a separate worker. The browser now shares the MCP permit. A gated regression verifies that a timed-out call keeps the permit until its underlying operation returns: the browser receives busy, makes zero planner calls, then the permit becomes available after joined cleanup. Call-graph review found no nested acquisition in the changed browser route. Sequential model switching still must preserve cancellation and stop/await-exit behavior, and broader whole-app inference/resource qualification remains open.

## Fixed acceptance scope

Freeze natural-language cases and expected outcomes before execution. Include ordinary wording and typo/paraphrase variants of information requests, explicit prohibitions, conditional future effects, quoted text-entry requests, and clarification turns that add or withdraw work. Keep exact user inputs and external expected outcomes separate from model context. Report semantic errors even when a conservative rejection prevents an unsafe completion.

For the first live browser milestone, retain a small fixed set: a source-grounded public information task, a task with a prohibition, a task with genuinely outstanding requested work, and login/Resume plus Stop. Existing BART and SFJAZZ tasks are useful regression inputs, not special cases in implementation. Judge the whole goal, source/entity association, prohibited effects, actual dispatch receipts and absence of duplicate effects externally. Record partial completion honestly.

Also record latency, peak managed-worker memory, cleanup and overlapping inference. The 12 GB whole-Mac target requires app/browser/system overhead assessment beyond the worker cap. No model promotion or general-computer-use claim follows from one successful browser task.

The original research involved no execution. Subsequent implementation and executed attempts are recorded in `browser-orchestration-results-sept23.json`; failures are retained alongside passes. The separate Jev research branch adds no runtime dependency to this repair.

## Observed protocol defect

Two frozen SFJAZZ model runs produced the correct factual answer but invalid free-text evidence: literal quotation marks, then invented JSON fragments inside the evidence string. A clearer prompt did not fix the second attempt. Both remained rejected. The implemented repair replaces evidence copying with schema-enumerated references to current native records; the host resolves the selected reference to its observed bytes. This addresses an observed serialization failure. Reference validity still does not prove that the model selected the right evidence or preserved every requested outcome.

The two new reference tests first failed, then the final 23-method focused batch passed. Text, tooltip, accessible link label and current-page source resolve separately to their captured bytes. Apple record windows keep at most 64 evidence choices; the managed whole-page llama path retains its existing token/context budget. The subsequent unchanged Qwen run still failed: it supplied a correct factual answer while leaving every requirement pending and evidence empty. The host rejected it. This is a model-planning inconsistency, not a passing end-to-end result; broader model and live qualification remain open.


## Bounded alternative-model comparison

A single standalone Agents-A1-4B Q4_K_M proposal reused the exact failed Qwen request, including every message, schema, seed and sampling field. Only the candidate weights and pinned author non-thinking template changed; the same b9992 runtime, 4096-token context, 768-token output limit, two CPU threads and 4 GiB worker cap applied. No application source, default model, effects or downloads changed.

The response matched the original informational oracle: the $25 fee and Contributor membership condition reference `text:t11`, the 48-hour deadline references `text:t12`, and the official URL references `source`. It preserved the prohibition on returns and purchases and marked the four information requirements observed. Proposal time was 9.59 seconds; startup through joined cleanup was 10.68 seconds, with 2601 input tokens, one worker and 3,083,862,016 sampled peak bytes (2.87 GiB). The owned worker exited and its temporary credential was removed.

This one response was reviewed against the captured records; the production Swift decoder was not executed with this candidate. Earlier Agents-A1 trials incorrectly completed unperformed ticket-return and conditional-work goals. Those failures remain unresolved, so neither model promotion nor general readiness follows. Candidate-template production loading, remaining fixed language cases, complete live workflows and whole-Mac resources still require qualification. All exact inputs, outputs and launch settings are retained under `.build/repair-verification/orchestration-agents-a1-original-01`, with the result included in the September 23 archive.

Both controlled specialist-handoff tests were repeated on the final compiled source and passed. Together with the 23 focused methods, that gives 25 passing methods on this source; it is not a full-suite pass or model qualification.


## Generation schema and subsequent qualification failures

The standalone candidate was replayed through the production request builder, native response decoder and completion validator. Its original good response was accepted; the exported request bytes matched the earlier managed request exactly. The embedded Agents-A1 template is byte-identical to the retained author template (8,979 bytes; SHA-256 `dd65e4c6e20ea9e7d5d3d98d4f625c1e20136d2d0112b66dcf9db5d361ff5f02`). A new original probe using production native-text launch flags reproduced identical completion content in 9.27 seconds with a 3.05 GiB sampled peak. Production candidate loading remains unimplemented.

The next fixed case, purchase after approval, failed. It emitted `answer` with pending approval, an observed action, and a nonempty worker objective. The actual decoder rejected it. A generic JSON Schema regression exposed eight such invalid combinations; only two positive cases passed before repair. The local text adapter now emits disjoint complete-object `oneOf` branches matching these existing decoder rules, including bounded requirement counts and evidence references. No instruction, user input, shared Apple schema, decoder or model default changed. Three focused app tests and all ten schema cases pass. One test qualifier compile failure is retained.

The representation follows the pinned [llama.cpp converter](https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/common/json-schema-to-grammar.cpp) and its [documented schema limitations](https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/grammars/README.md): each alternative owns its full properties; no sibling properties are mixed with `oneOf`, and no unsupported conditional schema is used. The decoder still enforces byte limits, nonblank values, unique instructions and unfinished work at handoff. Structural conformance cannot establish semantic correctness or a missing native capability.

The unchanged conditional request then generated valid JSON but still failed semantic review: Agents-A1 delegated opening/reading an already-observed page to visual control and weakened purchasing into preparation. Its structural action-pending replay passes, which is explicitly **not** semantic acceptance. A single reasoning-enabled diagnostic retained the prompt, context and grammar, changing only `enable_thinking=true` and output allowance to 1024 under the existing 512 reasoning budget. Exact input count was 2565, within the 4096 context budget plus reserve. In 17.30 seconds it omitted the purchase from its requirements, invented observed navigation and chose completion; its nonempty answer reference also failed app decoding. Neither profile is qualified.

Finally, the actual managed default Qwen run with the new grammar chose an unnecessary confirmation question rather than answering the unchanged observed information task (10.11 seconds, one worker, 3.08 GiB sampled peak, clean exit). No broader live run followed. These failures motivate separately qualifying a simpler goal-interpretation and page-step contract, not adding more recovery logic or treating a self-authored checklist as proof. Full task persistence, capability-gap qualification, effect receipts, provider login and whole-Mac resource acceptance remain open. The complete evidence is in `browser-generation-contract-results-sept23.json`.

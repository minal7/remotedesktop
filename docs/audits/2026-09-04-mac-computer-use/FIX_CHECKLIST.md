**Ordered repair checklist — Mac local-AI computer use**

Companion to [the detailed audit](AUDIT.md). Baseline: main at 603e79e9f877a4a1c9a0b462d8db4da06dc46cf2. These boxes describe proposed implementation work; the audit did not implement these fixes.

**Phase 1 · Make evidence trustworthy and define the supported product**

- [ ] **F29:** Replace the stale expected count of 138 with reviewed test-identifier discovery/validation. Current source selection is 167 methods. Update the Python contract test so it detects inventory drift instead of asserting a literal.
- [ ] **F29:** Split current visual-only package acceptance from future V4/V5 semantic-package qualification. Current acceptance must test the currently shipped manifest and router.
- [ ] **F30:** Extract a testable Mac core module for policy, task state, wire contracts, parsers, and model adapters. Execute its tests on every PR without privileged-host provisioning.
- [ ] **F18:** Specify supported OS, Apple Intelligence availability, languages, task families, and degraded modes. Replace ambiguous overall readiness with capability readiness.
- [ ] **F27:** Decide whether computer use is a same-LAN feature or must work remotely. Specify the authenticated transport and offline/disconnected behavior.
- [ ] **F28:** Freeze a held-out task corpus and a baseline measurement format before changing planners or prompts.

Exit criterion: the current package has runnable, correctly named gates; documented capability claims correspond to actual production composition. A missing provisioning profile is recorded as a build prerequisite failure, not a failed model task.

**Phase 2 · Introduce task state and reconcile interruptions**

- [ ] **F01:** Add TaskContract and Step records with IDs, outcomes, dependencies, entity bindings, constraints, preconditions, expected effects, and postconditions.
- [ ] **F02:** Compile goal-authorized intermediate actions through reviewed capabilities. Separate literal payloads, generated drafts, and observed data.
- [ ] **F03:** Replace task-global TYPE/ENTER suppression with idempotency per step, target, operation, and payload version.
- [ ] **F04:** Preserve task and step state through pause/resume. Re-observe and reconcile on resume; invalidate old coordinates and approval tokens.
- [ ] **F26:** Add attempted/verified/uncertain step states and durable recovery for effects that can outlive the host process.
- [ ] **F24:** Pass reviewed typed evidence and step progress across structured and visual executors.
- [ ] **F16:** Define completion as all requested outcome predicates proven, rather than a model stop token or a broad success phrase.

Exit criterion: two fields can receive the same value, two searches can submit, and pausing after any step does not replay completed work. An uncertain effect is neither auto-retried nor reported as complete.

**Phase 3 · Deliver one reliable text-editing vertical slice**

- [ ] **F05:** Implement TextEdit with explicit insert/replace/append mode, exact payload, target reference, initial-state requirements, and a verifier.
- [ ] **F06:** Bind it to application/window/document generation and element identity. Validate selection/value state where appropriate.
- [ ] **F07:** Preserve leading/trailing whitespace and newlines. Store exact text outside the model and route using payload IDs.
- [ ] **F07:** Separate host-owned payload size from model schema limits. Support bounded chunked edits or reject unsupported lengths before input.
- [ ] **F09:** Implement a reviewed AX value/edit action where supported; retain Unicode CGEvent entry as a fallback.
- [ ] **F05:** Read back resulting state and classify verified, rejected, or uncertain. Never infer acceptance from event emission alone.
- [ ] **F08:** Move long observation/input work off the UI execution path and make input chunks cancellable.
- [ ] **F25:** Bind exact approval to content, destination, consequence, and the current step; retain the existing one-use approval protections.

Exit criterion: complete the field tests T01–T10 below on controlled native and browser fixtures. A dropped or partial edit must be detectable. Successful exact text means equality under a documented app-specific normalization rule, not substring presence.

**Phase 4 · Build a coherent observation and targeting layer**

- [ ] **F11:** Use one ScreenCaptureKit-based observation service with frame ID/time, display ID, window/document identity, coordinate transforms, and generation.
- [ ] **F13:** Scope planning, grounding, freshness, and verification to the same authorized region/document.
- [ ] **F09:** Add an AX element snapshot/query/action/notification adapter with short-lived target references.
- [ ] **F10:** Add an explicitly owned browser context or scoped user-tab adapter. Keep the currently blocked ambient Safari tools blocked until replaced or repaired and independently validated.
- [ ] **F14:** Replace generic exact-image equality with action-specific target preconditions. Retain image checks as supporting evidence.
- [ ] **F12:** Add high-detail target crops and validate every transform. Use structural target resolution before spending an inference on a known element.
- [ ] **F15:** Preserve OCR geometry, confidence, source frame, and locale. Avoid silently promoting normalized OCR into verified facts.

Exit criterion: T11–T17 pass. Tiny targets are benchmarked; unrelated animation does not cause repeated replanning; changes to the real target do invalidate the action.

**Phase 5 · Make execution and safety measurable**

- [ ] **F17:** Add task/stage deadlines, meaningful-progress detection, repeated-state detection, and bounded recovery.
- [ ] **F17:** Replace fixed delay assumptions with AX/browser notifications and bounded observation polling.
- [ ] **F16:** Add capability-specific outcome verifiers, including all parts of compound tasks and stale-result rejection.
- [ ] **F25:** Classify consequential effects by capability and context rather than English UI labels alone. Test localized and deceptive labels.
- [ ] **F08:** Measure and enforce a takeover latency budget under capture/OCR/inference/input load. Preserve held-key/button release.
- [ ] **F31:** Add privacy-bounded structured traces with task/step/observation IDs, durations, policy reason codes, and outcome status.
- [ ] **F31:** Extract components incrementally behind existing seams; remove duplicated language rules only as equivalent behavior is covered.

Exit criterion: T18–T23 pass. Every failure has a useful stage/category; terminal success requires evidence. No new effect starts after cancellation ownership has been established.

**Phase 6 · Choose the local-model architecture using evidence**

- [ ] **F19:** Budget full Apple prompts, including tools, instructions, observations, history, and output. Add relevant-tool selection and explicit overflow recovery.
- [ ] **F18:** If Apple Intelligence is optional, implement an independent semantic planning path and run it from the actual installed package with Apple unavailable.
- [ ] **F20:** Decide whether Granite is a planner, candidate selector, or verifier. A one-candidate Apple proposer plus Granite filter must be described and evaluated as such.
- [ ] **F20:** For candidate selection, measure candidate recall and selector errors independently. Measure the second model's incremental benefit and cost.
- [ ] **F21:** Compare the exact Pro grounding package with structural/OCR baselines and suitable grounding alternatives, including quantization and image preprocessing.
- [ ] **F22:** Activate native and structured capabilities independently from visual-model installation/loading.
- [ ] **F23:** Implement pressure-aware/idle resource policies and measure future compact worker-switching costs on physical low-memory hardware.

Exit criterion: the chosen architecture improves held-out task completion or operational cost. A second model is retained only if that benefit is measured. Claims about 8 GiB support reflect real-device evidence.

**Phase 7 · Qualify the complete product and release**

- [ ] **F28:** Run the exact signed candidate host and matching mobile client through automatic enrollment, authenticated prompt/result, visual sidecar, pause/resume, approval, and terminal outcome.
- [ ] **F27:** Exercise the network scenarios promised by the product: same LAN, VPN/remote if supported, network transition, and reconnect.
- [ ] **F23:** Run the same supported task suite on physical 8/16/32 GiB tiers as applicable, cold and warm, under realistic workload.
- [ ] **F28:** Evaluate held-out phrasing, layout variation, repeated actions, and interruption points. Keep actual-model results separate from fixtures with stubbed decisions.
- [ ] **F30:** Run signed native integration and release trust checks without weakening notarization, runtime signing, or TCC requirements.
- [ ] **F18:** Update readiness messages and release notes to the tested capability matrix.
- [ ] **F28:** Publish a candidate-release evidence record identifying source commit, model hashes, runtime version, OS/hardware, tasks, failures, interventions, and accepted limitations.

Exit criterion: all critical regressions pass, all supported task families meet their agreed success targets, and the release report clearly distinguishes successful completion, appropriate intervention, unsupported scope, and execution failure.

**Concrete acceptance cases**

| ID | Scenario | Required observation |
|---|---|---|
| T01 | Type exact leading/trailing spaces and newlines | Exact intended value is preserved |
| T02 | Type emoji, combining marks, and non-Latin text | No corrupted or lost graphemes; verified result |
| T03 | Insert versus replace a selection | Correct mode and field contents |
| T04 | Fill two fields with the same city | Two distinct verified steps; no duplicate suppression |
| T05 | Perform two searches in one task | Two legitimate Return actions, each bound to its step |
| T06 | Drop some synthesized input in a controlled fixture | Partial text detected; no false success |
| T07 | Pause midway through typing, then resume | Current field reconciled without duplicate prefix |
| T08 | Navigate or replace the field at the same position | Stale edit rejected |
| T09 | Type a 2,000-character literal | Exact edit or explicit no-effect preflight rejection |
| T10 | App validation/autocorrection/IME changes the input | Verifier detects meaningful divergence |
| T11 | Target on another display with negative origin | Correct target/display or explicit unsupported result |
| T12 | Move or resize the target during grounding | Old coordinates are never used |
| T13 | Animate an unrelated part of the window | Stable target remains actionable |
| T14 | Change a background window with matching labels | Focused task is unaffected |
| T15 | Two same-labelled controls or browser tabs | Context resolves the target or asks for clarification |
| T16 | Tiny icons and dense tables at multiple scales | Measured target accuracy; appropriate crops |
| T17 | Low-confidence OCR for numbers/currencies | Re-observation or uncertainty, never invented precision |
| T18 | Local/remote takeover during OCR, model load, drag, typing | Bounded stop latency and released held input |
| T19 | Duplicate/delayed approval after pause | No action under the stale approval |
| T20 | Crash before, during, and after an effect | Verified recovery or explicit uncertain outcome |
| T21 | Localized Send/Continue and deceptive search context | Correct effect policy and exact approval boundary |
| T22 | Stale success banner and half-completed compound task | No premature task completion |
| T23 | Slow loading and a repeated no-op | Bounded useful waiting; clear deadline/stuck outcome |
| T24 | Apple unavailable and near-limit prompt context | Honest capability handling; tested budget behavior |
| T25 | Missing visual model but valid structured operation | Independent capability remains available |
| T26 | Network transition, lease expiry, reconnect | Consistent ownership and no duplicate task/effect |
| T27 | Physical low-memory Mac under browser/media load | Measured latency/memory and deliberate degradation |
| T28 | Actual production manifest through mobile-to-Mac flow | No stubbed planner/grounder or wrong-package substitution |

Use native/browser fixtures and test accounts for controlled effects. Real user emails, purchases, or credential entry are not required to exercise the transaction and approval design.

**Measurement contract**

For each attempted task, record one terminal outcome: completed and independently verified; user intervention required; unsupported; failed; or uncertain effect. Also record action count, model calls, recovery count, approval count, cold/warm end-to-end and per-stage latency, peak memory pressure, and takeover latency.

Choose product targets before optimization. As a starting proposal, require zero false completions and zero unauthorized effects in the release corpus, all critical deterministic regressions passing, and at least 95% independently verified success on the explicitly supported task families. These are proposed gates, not measured current results or proof of universal safety. Report trial counts and uncertainty; a small hand-picked passing demo is insufficient.

**The first three changes to implement**

1. Repair test discovery/current-package gates and create the nonprivileged core test target.
2. Add TaskContract/Step state with correct repeated-action identity and pause/resume reconciliation.
3. Deliver the verified TextEdit path on one native form and one browser form.

Only then broaden capabilities and evaluate whether an additional model pays for its latency and memory.

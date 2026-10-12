[Controlling general-agent plan](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/general-agent-plan.md>) — supersedes the release milestone order and task-specific job work.

| Phase | Status | Evidence / next step |
| --- | --- | --- |
| 0 — Freeze and branch | committed | `4b153a1`, tag `pre-general-agent`, branch `codex/general-agent`; all 40 files preserved as requested. Snapshot compiles; latest focused run was 46/48 passing, not a green baseline. Job-specific runs stopped. Safari bridge retained. |
| 1 — Shared contracts | compiled / tested | Three schemas, Swift Codable and Python wire types, v1 prompt (158 system words + schema + 3 examples). Shared corpus:52 cases. Focused Xcode7/7, Python13/13 and existing harness136/136 pass; packaged schema/prompt bytes verified. Full legacy suite remains unaccepted until Phase3. |
| 2 — Single general loop | pending | AgentLoop, Web/Mac environments, one local VLM policy, generic ActionGate and local trajectory recorder; every request enters the loop. Safari extension provisioning complete: production-ID Debug build and bundle trust verification passed; correct App Group embedded. Live bridge execution remains unverified. |
| 3 — Remove obsolete pipelines | pending | Delete task/planner code with tests, split manager, rename runtime, enforce no hardwiring; ComputerUse ≤30k lines, full suite green ≤10min. |
| 4 — General evaluation | pending | 120 basics tasks, safety suite, 20-task smoke subset, YAML runner and fixture server in resettable tart VMs. |
| 5 — Policy baseline | pending | Evaluate Fara plus 2–3 licensed 4B–8B VLMs via policy adapters; report by skill, latency and memory; owner picks base. |
| 6 — Training pipeline | pending | Shared-loop teacher trajectories, filtering, LoRA/GGUF and promotion checks; owner approval of teacher terms and GPU cost required before use/spending. |
| 7 — Product integration | pending | After first promoted model: task summaries, history deletion, trust settings and model version; general-suite release gates. |

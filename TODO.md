[Controlling release brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/release-brief.md>) — October 12 release scope and R1–R6 order; agent working rules still apply.

| Job | Status | Blocker |
| --- | --- | --- |
| R1 Safari DOM bridge | in progress | R1.0 transport compiled; latest focused host tests246 passed/10 existing opt-ins skipped (after dormant-router deletion), Node bridge11/11. Live spike blocked by Safari appex App Group provisioning; p95,idle,relaunch and unavailable timing remain unmeasured. No full DOM tools until spike report. |
| R2 Drive / Dropbox on bridge | not started | After R1; retire the W2 AX approach.10/10 each,5 root+5 named,median≤45s,zero native panels,fresh-tab checker. Dropbox sign-in owner prerequisite. |
| R3 Gmail on bridge | not started | After R2; existing AX drafts10/10 and Send-approval3/3 are historical, not G1 evidence. Bridge median≤60s,zero native panels. |
| R4 Flights | not started | After R3; bridge read-only,10 seeds,≥9/10 cheapest correct,0 hallucinated prices,median≤120s. |
| R5 Away | not started | After R4; encrypted CloudKit task channel,lock handoff,availability and push. Owner capabilities/schema/physical cellular iPhone required. |
| R6.2 Release gate runner | in progress | release_gate.sh implemented; harness136/136 and Node bridge11/11 pass. Report-only: G1–G12 FAIL. Full-suite execution and fresh xcresult proof required; partial inventories/build-for-testing cannot pass G7. Remaining gate checkers still need implementation. |
| R6 Release hardening | in progress | Retired OSAtlas executor/install path, Llama semantic router and V5 candidate selection with matching tests; shared action/credential/token-budget contracts retained. Latest focused build246/246 passing plus10 existing opt-in skips. October12 full Xcode run timed out at900s:2,463 completed,1,980 passed,155 failed,328 existing opt-ins skipped; no complete comparison. PR CI now runs full Xcode target; YAML parses, remote CI not run. |
| Apple Mail | passing 10/10 | Historical accepted path frozen; release G4 still requires current acceptance evidence. |

Known limitations:
- R6 permission experiment complete: no Documents dialog appeared; source enumeration audit moved to the existing Python harness and passes. Focused unsigned Xcode tests now finish; no production permission expansion.
- R6 router deletion compiled/tested:4,600+ obsolete lines removed; active Foundation JSON escaping is unchanged and template/tokenizer coverage uses the active text planner. Preserve Fara/nativeText, send approvals/fingerprints, secure-field rules, enrollment/pairing and WebRTC.
- R1.0 signing blocker: the installed Mac profiles lack App Group membership and there is no Safari appex profile; live transport is not accepted.
- ≤30min packaging experiment: Apple's Safari converter confirmed flat extension resources; bundle inspection found the LaunchAgent outside Contents. Align both paths and keep exact XPC peer signatures.
- ≤1day supported redesign: the container-free relay helper is unsandboxed without restricted entitlements; only the appex claims the required App Group. Continue deterministic checks while owner provisioning is pending.
- No release gates passed yet. Gmail historical median132.2s exceeds release target. Drive AX is retired at0/10;5fbe695d timed out with unknown effects and is retired/no replay. Temporary probes removed; no more AX patches.
- Last complete host run:154 failures/372 skipped; October12 partial run has155 failures,20 absent from that older baseline. Investigate all failures; baseline matching no longer excuses them. Two legacy crashing tests were deleted with their executor. No new skips.
- The old SwiftPM test composition is broken by app/client dependencies; it is retired from PR CI. Experimental native acceptance caller migration is deferred with OS-level work.
- Release scope is Safari plus the four named jobs; arbitrary web/Fara,sync-folder copy,native/in-house apps stay Experimental off. No Chrome/newsites/model evaluations.
- Owner actions needed: test Safari Google/Dropbox sign-in; enable extension and website access when concrete bundle is ready; approve helper LoginItems if requested; Push Notifications/CloudKit schema Production; physical iPhone cellular; fresh16GBmacOS account; merge and release/TestFlight upload.
- Owner approved a draft PR after local gates pass (October12), resolving the G7/G10 chronology. Merge and release workflow remain owner actions.

- R6 timing experiment compiled/tested: per-session fixture deadline reduced two synthetic ownership tests from60.26s to0.77s combined. Production30s, single-Cmd+N and fail-closed assertions remain unchanged.

- R6 clarification/form-query repair compiled/tested: focused RED reproduced4/4 failures; GREEN21/21 host and3/3 iOS, zero skips. Raw invisible format controls are rejected before trimming; invalid iPhone answers retain exact drafts and stay unsent.
- Corrected test-only HTML form query interpretation and sequential journal fixtures; production encoding, continuation authority and no-replay checks remain intact.

- ≤1day R6 research-route deletion slice: the old WK research driver is never constructed by production composition; Safari bridge jobs replace that route.
- Remove only CapabilityExecutor research injection/routing and its dedicated route tests; keep manager compatibility, shared DOM/Fara/form code, and existing unrouted-response validation.
- Compiled/tested: native/desktop routing and all migrated manager clarification/lifecycle callers pass30/30 with zero skips; broader research helpers remain pending and are not counted finished. Test fixtures retain exact Resume owners and use the existing navigation tool.

- ≤1day R6 scope repair: fresh generic web/native goals currently reach effects before release-job admission; add the required default-off Experimental setting.
- Use the existing typed job route at the manager boundary before executor dispatch; keep approved actions, scoped answers and admitted Resume authority unchanged.
- Compiled/tested: the authenticated decline, supported jobs, preference and Resume tests pass; continuation/default-browser regression tests bring this slice to98 passes, zero failures and16 existing opt-in skips. No live acceptance is counted.

- ≤30min R6 window-fixture experiment: existing DOM/native-picker cases fail frontmost-window checks; first reproduce one selector against the already-built pre-scope binary.
- Determine whether blank-session capture can establish and verify the real owned window before fixture navigation; keep all production presentation, picker and authority checks.
- Blocked: corrected blank-session preflight fails before navigation because UserNotificationCenter owns the foreground; Computer Use refuses access to that system app. Owner dismissal requested; production guards/deadlines unchanged and no acceptance counted.

- ≤1day R6 resolver cleanup: legacy OS-Atlas Pro/two-model resolve APIs have no production callers; Fara/Holo/nativeText use separate resolver entry points.
- Remove those dead APIs and their seven dedicated tests; preserve pinned-data, bundled-executable, symlink and legacy-rejection checks on the shipped entry points.
- Compiled/tested:14 remaining resolver tests pass with one existing opt-in skip, including bundle boundaries, internal/escaping/broken symlinks and legacy rejection. This is source cleanup, not live job acceptance.

- ≤1day R6 research-driver cleanup: the concrete WK research driver has no production constructor after the routing retirement.
- Remove the driver and only tests/helpers that instantiate its lifecycle; preserve static fixtures, pure planner contracts, active DOM/Fara/native picker and model-lifecycle safety tests.
- Root reviews the method-level deletion, regenerates the project/inventory, then builds and runs retained safety tests before committing; no recreated research route or new skips.

[Controlling release brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/release-brief.md>) — October 12 release scope and R1–R6 order; agent working rules still apply.

| Job | Status | Blocker |
| --- | --- | --- |
| R1 Safari DOM bridge | in progress | R1.0 transport compiled; focused host tests261 passed/10 existing opt-ins skipped, Node bridge11/11. Live spike blocked by Safari appex App Group provisioning; p95,idle,relaunch and unavailable timing remain unmeasured. No full DOM tools until spike report. |
| R2 Drive / Dropbox on bridge | not started | After R1; retire the W2 AX approach.10/10 each,5 root+5 named,median≤45s,zero native panels,fresh-tab checker. Dropbox sign-in owner prerequisite. |
| R3 Gmail on bridge | not started | After R2; existing AX drafts10/10 and Send-approval3/3 are historical, not G1 evidence. Bridge median≤60s,zero native panels. |
| R4 Flights | not started | After R3; bridge read-only,10 seeds,≥9/10 cheapest correct,0 hallucinated prices,median≤120s. |
| R5 Away | not started | After R4; encrypted CloudKit task channel,lock handoff,availability and push. Owner capabilities/schema/physical cellular iPhone required. |
| R6.2 Release gate runner | in progress | release_gate.sh implemented; harness136/136 and Node bridge11/11 pass. Report-only: G1–G12 FAIL. Full-suite execution and fresh xcresult proof required; partial inventories/build-for-testing cannot pass G7. Remaining gate checkers still need implementation. |
| R6 Release hardening | in progress | Retired OSAtlas executor/install path and matching tests removed; shared action/credential contracts retained. October12 full Xcode run timed out at900s:2,463 completed,1,980 passed,155 failed,328 existing opt-ins skipped; no complete comparison. PR CI now runs full Xcode target; YAML parses, remote CI not run. |
| Apple Mail | passing 10/10 | Historical accepted path frozen; release G4 still requires current acceptance evidence. |

Known limitations:
- R6 permission experiment complete: no Documents dialog appeared; source enumeration audit moved to the existing Python harness and passes. Focused unsigned Xcode tests now finish; no production permission expansion.
- R6 next deletion slice: dormant Llama semantic router and V5 candidate selection still remain, with semantic-only runtime methods/tests.
- ≤1day: preserve the active planner's JSON escaping helper, delete the dormant code and matching tests, then compile and run focused checks.
- Preserve Fara/nativeText, send approvals/fingerprints, secure-field rules, enrollment/pairing and WebRTC; keep the full deterministic suite visible in CI.
- R1.0 signing blocker: the installed Mac profiles lack App Group membership and there is no Safari appex profile; live transport is not accepted.
- ≤30min packaging experiment: Apple's Safari converter confirmed flat extension resources; bundle inspection found the LaunchAgent outside Contents. Align both paths and keep exact XPC peer signatures.
- ≤1day supported redesign: the container-free relay helper is unsandboxed without restricted entitlements; only the appex claims the required App Group. Continue deterministic checks while owner provisioning is pending.
- No release gates passed yet. Gmail historical median132.2s exceeds release target. Drive AX is retired at0/10;5fbe695d timed out with unknown effects and is retired/no replay. Temporary probes removed; no more AX patches.
- Last complete host run:154 failures/372 skipped; October12 partial run has155 failures,20 absent from that older baseline. Investigate all failures; baseline matching no longer excuses them. Two legacy crashing tests were deleted with their executor. No new skips.
- The old SwiftPM test composition is broken by app/client dependencies; it is retired from PR CI. Experimental native acceptance caller migration is deferred with OS-level work.
- Release scope is Safari plus the four named jobs; arbitrary web/Fara,sync-folder copy,native/in-house apps stay Experimental off. No Chrome/newsites/model evaluations.
- Owner actions needed: test Safari Google/Dropbox sign-in; enable extension and website access when concrete bundle is ready; approve helper LoginItems if requested; Push Notifications/CloudKit schema Production; physical iPhone cellular; fresh16GBmacOS account; merge and release/TestFlight upload.
- Owner approved a draft PR after local gates pass (October12), resolving the G7/G10 chronology. Merge and release workflow remain owner actions.

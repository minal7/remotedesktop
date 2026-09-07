# Bind browser handback to the paused task and session

Date: 2026-09-07. Parent source: `aa81a0c`. Source repair only. Builds, typechecking, test execution, model runs, application launches and computer-use activity remain paused.

## First-principles defect

Resume is permission to continue the original task after a manual step. It does not prove that a browser still exists, that it belongs to that task, or that signing in succeeded. The task needs to retain the browser relationship before yielding control and check that relationship before asking an executor for another action. A login redirect legitimately changes the document, so retaining only the old page identity would also be wrong.

The host previously called an optional browser helper for every Resume. A missing helper silently returned, and the raw browser method also returned when it could not find a matching browser. Its frontmost-window alternative could accept another owner. This made successful return ambiguous: it could mean that the same session had been reacquired, or that there was no browser to check. Subsequent native/semantic execution could proceed without distinguishing those cases.

## Source repair

1. A host-only handback requirement retains the root task ID, owned-browser context, actual WebView lifetime and ownership epoch. Its constructor is private to the browser source. It has no serialized/model-authored representation, and its ordinary/debug descriptions expose no page URL, credential or internal identity.
2. Browser lifetime and ownership are separate. Creating a replacement WebView changes its session identity. Claiming a different task changes the ownership epoch; returning to the original task ID cannot revive the old requirement. Stop and close also retire ownership.
3. Pause retains a requirement only for an existing browser owned by that task. A native task does not acquire another task's browser merely because it exists. Pre-delivered Pause, before the prompt starts, does not bind an earlier browser.
4. Typed browser-authentication failures require handback even if the browser has disappeared. An explicit unavailable requirement survives in the paused context and fails on Resume; a missing browser can no longer become an absent check. Generic executor intervention still uses the owned task relationship when available.
5. Resume passes the retained requirement through the host tools and navigation facade. Every raw handback call now requires it as well; the optional and silent-success paths are removed. Validation precedes document inspection and checks root task, browser context, WebView lifetime, ownership and open sign-in children. A handoff requiring presentation also requires the parent browser to be active. Existing cancellation, action-gate and page-loading checks remain in force.
6. The requirement deliberately does not bind the pre-login document generation or URL. Explicit handback can adopt a completed observed login redirect or a separately proved history change in the same owned session. Existing asynchronous observation checks remain, and the requirement is checked again after adoption. These observations do not become requested-navigation receipts or proof of account authentication.
7. A failed Resume preserves the original requirement and remains paused before entering the successor executor. Repeated Resume cannot recapture a replacement session. Closing/replacing the session gives explicit guidance; an open sign-in child or inactive required parent has its own guidance. Loading and other unavailable observations continue to ask the user to finish the manual step.
8. Successful handback consumes this pause's requirement after cancellation and execution-owner checks. The complete original user request, typed conversation and clarification state remain intact. A later pause can capture a legitimately new same-task session, rather than being pinned forever to an earlier browser. Historical approved-action reconciliation remains separate because it publishes a retained fact without starting another action.

The requirement is process-local continuity evidence. It does not restore a closed session, recover a task graph after host restart, establish the active account, or authorize a browser action by itself. Ordinary task/window Stop behavior remains terminal. Full task prerequisites must still decide whether the next step belongs in the browser or a native application; foreground state alone cannot make that decision.

## Prepared verification

Six new methods cover:

- Unchanged-session handback with no DOM read/reload, wrong task, another browser with the same task and URL, and ownership changing away and back.
- Stop/close, recreation in the same browser wrapper, rejection of an unavailable earlier session, and acceptance of a newly captured requirement only for a later handoff.
- Host-level login Pause followed by Stop/close and two failed Resume attempts: no successor executor, reload or terminal success.
- A typed authentication failure without a browser: explicit handback failure before a second execution.
- A paused native task with an unrelated browser that closes: native continuation keeps the original request without acquiring or reopening that browser.
- Two successive same-task handoffs with deliberate session replacement during authorized execution between them: successful handback is consumed and the next pause captures the new session.

Existing browser fixtures now retain explicit requirements before interruption, including login redirects, same-document history, popup opener/session continuation, cancelled identity reads, late loading and private callback URLs. The existing host fixture still requires an early loading-page Resume to remain paused and a later handback to retain session state and the exact original task. The opt-in visible popup fixture is updated for the required argument but remains excluded from the default source gate and unexecuted.

The [focused source inventory](browser-handback-binding-inventory.json) selects **195** methods: the preceding 188 browser/journal selection, six new methods and the existing host loading/session fixture newly included in this focused gate. The default inventory selects **717**, six more than the previous 711. Five changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. **No assertions, typechecking, builds, models or UI runs occurred.** Prepared cases and source parsing do not qualify runtime behavior.

## Remaining repair order

1. Connect the whole-browser task compiler and driver to retained form edits, observed links/queries, scrolling and durable effect records. Preserve the original requested dates, places, counts and other constraints as explicit remaining requirements across login and replanning.
2. Make each step's prerequisites explicit: browser/session, current document, account state where needed, intended form values and independently confirmed prior effects. Do not infer remaining work or success from Resume, navigation receipts, a familiar URL or the absence of a password field.
3. Define recovery when a session or document is lost. Existing durable attempts must continue to prevent blind replay. A new session or task needs explicit reconciliation of possible server-side effects; the handback requirement intentionally cannot manufacture that proof.
4. Complete site submission semantics and supported widgets, and verify travel, concert and movie results against the full request and current source pages. Authentication providers, external login windows, custom challenges and model-requested login without a typed browser observation still need qualification/integration.
5. After later explicit permission, typecheck/build and run the controlled gates, then the agreed bounded real-site scenarios. Actual login provider behavior, full installed host/phone workflows and OCR remain unqualified. Performance optimization follows correctness repairs; the 8 GB memory target and reported fan load still need measured qualification.

About 15 GiB remained free. This repair produced source/documentation and a small inventory only, with no build or result bundles. No obsolete generated cleanup target was needed. The user's standing cleanup authorization remains recorded in `TODO.md`.

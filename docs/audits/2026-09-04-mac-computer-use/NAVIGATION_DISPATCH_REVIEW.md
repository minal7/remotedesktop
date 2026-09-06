# Browser navigation dispatch repair

Status: source implementation and regression selection only. No compilation, test execution, inference, app launch or computer-use interaction was performed. Performance optimization and real-site scenarios remain deferred under the user's current instructions.

## Finding

`ComputerUseBrowserNavigationTask` compiles ordered URL requests into the shared step engine. For a later navigation, its preconditions require the previous navigation receipt to still identify the current document. The engine then persists an attempted step before invoking the adapter. Previously the adapter passed only the new URL to `ComputerUseOwnedBrowser.navigate`, whose final admission checked task ownership but not that previous document.

A same-task page reload or other document change could invalidate the prerequisite while leaving the browser owned by the task. A historical receipt and equal URL do not establish current document identity. This is the same distinction that future search/submission steps must preserve across edits, waits and navigation.

## Implemented boundary

- `navigate` accepts an optional expected document. A supplied document is checked before presenting the browser and again after presentation, immediately before generation changes, pending-navigation registration and `WKWebView.load`.
- The production ordered navigation adapter passes the previous step's exact receipt on every step after the first. A missing prerequisite fails instead of becoming an unconditional navigation. The first explicit URL command retains its existing task-owned navigation behavior.
- Stale documents use the existing intervention outcome. The existing attempted/uncertain journal state prevents automatic dispatch on resume when no receipt proves the later navigation.
- A fixture-only optional callback can suspend the adapter after the durable attempt and before navigation dispatch. Production supplies no callback, and the actual document guard remains inside the browser effect method.

## Deferred evidence

Two new source methods are registered. One distinguishes the current document from an older receipt at the same URL, a foreign context and a different task; it also proves a valid next transition remains available. The other uses a controlled local WebKit page whose held response triggers `location.reload()` after the second step is durably attempted. Browser ownership remains with the original task and its historical receipt remains available. The expected result is intervention, zero requests to the second URL, and no retry of that request on resume.

The [focused inventory](navigation-dispatch-inventory.json) selects 21 source methods across owned-browser navigation and the shared task engine, including existing repeated-navigation, cancellation, recovery, outcome and ownership checks. It and the 410-method default inventory match source. `git diff --check` passes. These are source checks, not executed acceptance evidence.

## Remaining workflow work

The owned browser currently exposes explicit URL navigation and retained text fields. It does not yet provide a production whole-goal compiler, retained form/submitter identities, a verified submission operation or a result-extraction contract for travel and ticket tasks. Those capabilities must distinguish filling a field, dispatching a submission and proving the requested results. Future asynchronous preparation must keep the expected document bound through the actual dispatch boundary.

This change checks the document state exposed by WebKit at native dispatch. It does not establish an atomic transaction with arbitrary later page scripts, independent proof of remote-site effects, or complete whole-goal success. Real browser/model qualification remains required once the user permits execution.

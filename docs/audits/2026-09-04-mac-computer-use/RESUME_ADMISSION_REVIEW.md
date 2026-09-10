# Preserve action gating and browser ownership throughout Resume

Source repair; execution pending. No build, typecheck, assertion/test run, app/browser launch, inference, live website task or SSH connection ran for this repair.

## First-principles findings

Handback needs continuous ownership. Accepting a Resume command is the start of validating a continuation, not permission for an old executor to use native tools while readiness and prior-execution cleanup are unfinished.

The [manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) previously reopened its action gate and published `idle` before checking executor readiness. An old retained tool object could observe the open gate during that synchronous check. A user-input callback in this interval had no pending automation claim to revoke; the later execution path created a new claim regardless.

Publishing `idle` also had a concrete browser consequence. The activity observer removed the task's browser controls. [Owned-browser control updates](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) close a provider window when its owner controls disappear. An early Resume could therefore destroy the in-progress sign-in context before the existing handback validation could report that its provider window was still open. The existing prepared popup-handback regression already required the child to remain open; it had not been executed under the current test pause.

## Repair

Resume now reserves a unique pending automation identity with the action gate closed before readiness checks or initial prompt claiming. Direct input can revoke that reservation synchronously. Execution must adopt the same reservation, then activate that same identity only after the previous execution has joined. It cannot substitute a new reservation after an input event revoked the original. A failed adoption preserves a paused continuation and records local intervention.

An unadopted reservation is abandoned on return. Successful adoption transfers it to the execution path, so the caller's cleanup cannot close a newer or already-adopted reservation. Stop, intervention and approval transitions clear pending identity and adoption state. Activation requires both the exact identity and adoption; the existing execution-token check still protects which task may attempt activation.

A started task retains its paused context and browser owner through readiness. The manager installs the successor context before publishing the working state. It no longer passes through an ownerless idle state, so an open provider window remains owned and can block handback as intended. Closing the provider still does not prove authentication or grant Resume; the existing current-page and native handback checks remain required.

A prompt paused before its first execution has no live browser handoff of its own. It re-enters the normal durable claim path under the same reserved admission. If input revokes that admission during the first readiness check, the executor is not invoked. A later explicit Resume retains the original task and trusted user prompt.

## Prepared verification

Three new [manager regression methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) are authored and unrun:

- Local and phone Resume retain the browser owner and paused controls during readiness, refuse an old tool object's attempted text input, honor an intervening input event, and permit a subsequent explicit handback without changing the trusted prompt.
- A prompt paused before delivery cannot recreate its reserved admission after input during its first readiness check; it executes once after a later current Resume.
- An unavailable executor leaves the original owner paused, abandons the reservation and keeps old tools blocked; a later ready Resume continues that task.

The [focused seven-method inventory](resume-admission-inventory.json) also includes the existing full provider-popup handback scenario, predecessor-join intervention, Stop followed by a new prompt, and a cancellation-ignoring executor's rejected stale tool call. The new readiness fixture retains its earlier tools and permits a controlled unavailable-readiness result; production tools and action gating remain in the exercised source paths.

Two Swift files pass parse-only checks. Source inventories select **1879 default host / 1196 focused host** methods; client core remains **34**. Syntax and source registration are not execution, typechecking, native input evidence, provider qualification or model qualification. Local documentation checks cover 211 Markdown files and 1,718 local targets with no broken targets. Whitespace checks are clean, and the effective hook directory contains no executable non-sample hooks.

## Subsequent paused-input ordering repair

At this checkpoint, further physical input while already paused was ignored and a delayed phone Resume could carry an older handoff epoch. The subsequent [paused-input ordering repair](PAUSED_INPUT_ORDERING_REVIEW.md) records scoped input occurrence, coalesces durable checkpoints and checks the same generation through Resume reservation. Both source repairs remain unqualified by execution.

The follow-up source repair implements the following sequence, with actual native and transport qualification still pending:

1. Record a bounded native indication of new manual input while the actual task owner is paused, without reading or retaining key contents, passwords or login data.
2. Scope the indication to the current task/control ownership so a delayed callback cannot affect a replacement task.
3. Reconcile it with the persisted host control epoch before a delayed remote Resume may be accepted. Coalesce persistence rather than write the ledger for every mouse movement or keystroke, while retaining a synchronous check through admission.
4. Treat an explicit local handback as an intentional command after the person's preceding input. The click on the local Resume control must not invalidate itself or make handback impossible.
5. Cover input on both the parent and provider windows, direct phone input, in-flight control replies, storage failures, repeated pause/resume and owner replacement. Keep Stop effective regardless of stale Resume metadata.

## Remaining qualification

Keep execution deferred until authorized. Then compile and run the selected cases and the actual login handoff composition, including early Resume, provider close, callback redirects and stale native objects. Continue complete-goal/action verification and durable native browser/account/process recovery. Global navigation-source completion remains restricted pending qualification.

After correctness repairs, qualify supported lightweight models and the total 8 GB Mac resource budget. The alternative-model and reported RTX 3080 desktop options remain available in the plan; remote access is still unverified after the earlier timeout. Real flight, concert, movie and account-login scenarios remain deferred for later explicit authorization.

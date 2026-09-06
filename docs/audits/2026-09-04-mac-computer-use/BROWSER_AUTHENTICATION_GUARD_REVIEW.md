# Recognize authentication before reading or editing browser forms

Parent source: `0380b2a`. Source repair and prepared regression coverage only. No build, test execution, model inference, app launch, computer-use activity or actual account login occurred. The user's execution pause and deferred performance work remain in force.

## First-principles problem

A browser form is not necessarily ordinary task data. Filtering `type=password` and `autocomplete=one-time-code` controls does not protect a verification code exposed as a normal text/number field, or a revealed password whose type changed to text. The old discovery loop could also collect earlier field values before encountering a later credential control.

The native form route ran before the desktop executor's authentication detector. It could therefore read those values or consider a form edit without reaching the existing manual-login handoff. The production text planner normally receives field labels rather than serializing values into its prompt; that does not justify collecting credential values into host-side snapshots or allowing them to become field-copy inputs.

The required sequence is: inspect metadata, identify a person-only authentication step, pause, preserve the task, and inspect again after explicit handback. Pressing Resume is permission to continue; it does not prove that login succeeded.

## Source change

The fixed script in the owned browser's isolated WebKit world now scans the bounded document and open shadow roots for active, rendered credential controls before any field-value collection. It uses declared input type/autocomplete purpose and bounded labels/identifiers, not field values. Password and OTP purposes, username autocomplete, and reviewed password/passcode/verification/recovery-code labels trigger a value-free `authentication-required` result.

Label matching uses complete normalized labels with bounded ordinary qualifiers, including common camel-case field identifiers. It does not classify an ordinary `Airport code`, `Postal code` or `Password policy` field from a single keyword. Hidden, disabled and read-only controls remain excluded from value reads; a saved read-only password display is not treated as an active login challenge. A rendered active credential remains recognizable even if the page gives it `aria-hidden` metadata.

This is a separate pass before discovery, so a later credential control protects earlier normal-looking inputs too. The same check runs before retained reads, form re-observation, representability checks and actual input dispatch. Page data and model output remain arguments, never executable JavaScript. The existing 10,000-element bound remains; an incomplete initial scan returns the existing no-value discovery decline, not a partial field array or a claim that authentication is absent.

`ComputerUseOwnedBrowser.callDOM` maps the dedicated result to a typed authentication error and rejects an inconsistent result containing fields. The host manager turns that error into the existing nonterminal local-intervention path, including the durable host control epoch, closed effect gate and retained request. It does not fall through to another planner or mark the task complete. An early Resume encounters the same barrier and pauses again with a newer epoch.

Native clarification preparation retains its exact answer and expiry through this authentication error, just as it retains them through an ordinary interruption. Explicit handback can continue that answer if its existing form and scope remain valid. Authentication does not renew the clarification lifetime or authorize a different task.

## Effects and continuation

Authentication can appear after an input event—for example when a page asks for verification before proceeding. The new guard must not erase proof of an earlier action. Historical input-receipt queries therefore remain value-free and available under the existing document/ownership checks; credential detection does not clear the receipt map or rewrite the task journal.

If authentication interrupts postcondition checks after a dispatched edit, the existing journal can retain an uncertain step. After handback, the unchanged document, original receipt and exact resulting value can reconcile that step and continue the planned suffix once. If the guard rejects before dispatch but after the task persisted an attempt, this repair does not invent a non-dispatch receipt or authorize a retry. That uncertain attempt still requires the existing recovery rules. Navigation, replaced targets or changed required values likewise remain stale; this is not general contract rebasing after login.

## Prepared regressions

Five DOM/native methods and one host/coordinator method are added:

1. Declared passwords, OTPs, numeric verification inputs, revealed passwords, identifiers/placeholders, username autocomplete, contenteditable controls and open-shadow credential fields block discovery, including when an ordinary input appears earlier.
2. Hidden/disabled/read-only credential controls and ordinary code/policy labels preserve supported field discovery.
3. Authentication appearing after discovery blocks all read/preflight/edit paths without emitting input or consuming its adapter operation ID. Removing the barrier permits fresh validation; this direct-adapter case makes no task-journal retry claim.
4. Authentication appearing in the first input handler stops postcondition checks and the second edit. After the barrier clears, native execution reconciles the original receipt and finishes the suffix without repeating the first input or replanning.
5. Authentication during a scoped answer preserves the exact prepared clarification. No second planning call or text journal appears until the barrier clears; the same answer then completes once.
6. The production host manager, capability coordinator and native text executor encounter a controlled verification field before planning. They publish a resumable pause, reject an early handback by pausing again, and complete the unchanged literal field request after the fixture removes verification. There is one fixture-page load, one edit, no model call, no terminal reply during authentication and no credential in the status bodies. Task replay adds no input.

The host fixture preloads a controlled form inside its native-execution callback. It does not search for a website or perform provider authentication. Removing a fixture field is not evidence of a real successful login.

The reviewed source inventories contain **581 default host methods** and **50 focused methods**. Inventory identity checks and `git diff --check` pass. These are source checks, not compilation or executed assertions. See the [focused inventory](browser-authentication-guard-inventory.json).

## Remaining browser/login work

- Qualification must cover real provider forms, passwordless flows, MFA/passkeys, popup windows and session expiration. These English metadata rules cannot reliably identify every custom, unlabeled or translated credential control. Closed shadow roots and embedded-frame authentication need separate observation/ownership work.
- The visual and native AX routes need their own complete authentication/value-redaction review. This guard covers owned-browser DOM form values and effects; it does not qualify screenshot privacy, account selection or arbitrary desktop login handling.
- Absence of a recognized credential control is not proof of account identity or successful login. Full browsing goals still need page/account predicates and verified remaining outcomes.
- Review OAuth/callback URL handling before provider qualification: exact URLs are needed internally for document identity, but token/code-bearing query or fragment values must not become model context, status text or durable task logs.
- Complete remaining-goal rebinding and explicit non-dispatch recovery for interrupted steps; preserve historical effects and never silently replay uncertain input.
- Measure the added bounded metadata scans in the deferred resource phase. No 8 GB or thermal qualification follows from this change.
- Compile and execute the prepared fixtures only when authorized, then request the separately required permission for bounded real travel/concert/movie/account scenarios.

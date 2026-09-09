# Request manual sign-in from an observed entry

Source repair; execution pending. This extends the existing [authentication guard](BROWSER_AUTHENTICATION_GUARD_REVIEW.md), [browser login handback](BROWSER_LOGIN_HANDBACK_REVIEW.md) and [task/session binding](BROWSER_HANDBACK_BINDING_REVIEW.md). No browser, app, model, account login or test workload executed.

## First-principles defect

The person must control credential entry and account permissions. An app also needs a way to request that help before a password or verification field appears. A ticket page may show only a sign-in entry, leaving the user to open the provider's flow.

The native authentication guard already interrupts observation when it detects an active credential field. The research action planner had no explicit manual-login request tied to an observed entry. It could return a generic unsupported-step intervention, but could not distinguish that account step while preserving the original research task. Making the AI click or fill a login form would not repair this missing control transfer.

## Source changes

The [action planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) offers `login_handoffs` only for sign-in entries present in its bounded public page projection. The initial matcher recognizes complete English sign-in/log-in labels, a small set of ordinary qualifiers, and explicit Apple/Google/Microsoft/Facebook provider-entry labels. It excludes generic Continue, Account, sign-out, registration, help/policy text, mixed instructions and oversized labels. HTML button/submit controls must be enabled and not read-only; links must already be visible in the native page projection. No private destination URL or credential value is added to this context.

Each `loginN` alias points to an observed public control/link reference on this input. Context and response-schema version 26 offer only `{"login_handoff":"loginN"}`. Unknown aliases, other value types and hybrid roots are rejected. The choice is withheld during an active form scope/preparation review; it cannot abandon unfinished effect preparation. Existing credential barriers and visible task controls still apply there.

Instructions distinguish optional account navigation from required account access. The planner should continue public research when possible and request manual login only when the complete task needs it. The label establishes an observed entry, not proof that authentication is necessary, that a provider is genuine or that an account is already authenticated.

The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) accepts only its latest proposal under the current goal. It revalidates the exact native page snapshot, checks cancellation/ownership again, and pauses the original task. It issues no click, navigation, popup, form input, account action or query receipt. A fixed message asks the person to use the AI browser and then choose **Let AI continue**; page text, URLs and account values cannot become the status message.

The [research driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) returns this through the existing nonterminal user-intervention result. The task remains paused until explicit handback. Existing handback rechecks the same browser session and current page; a credential field still present blocks an early Resume. Absence of that field still does not prove account identity, successful login or completion of the original request.

## Prepared coverage and permitted checks

Four new methods are authored and unrun:

- Three [action-planner methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserActionPlannerTests.swift) cover complete labels versus misleading text; native button/link projection, disabled/hidden controls, strict references and private-URL exclusion; and changed-page/cancellation rejection before publishing the handoff. An existing strict decoder case also rejects a handoff alias when none was offered.
- One [driver method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchDriverTests.swift) requests manual sign-in without following the entry, checks paused continuation, rejects an early handback at a credential field, then prepares continuation of the same goal without repeating the initial search. Controlled fixture navigation stands in for user work; it is not real authentication or a public ticket-search test.

Five changed Swift files pass parse-only syntax checks. The maintained default/focused source inventories select 1703 / 1020 methods, with four additions and no removals. No build, typecheck or assertion result is claimed.

## Remaining work

Recognizing an entry and transferring control do not qualify provider login flows. Translated/custom controls, closed shadow roots, embedded frames, real MFA/passkeys/CAPTCHA, provider refusal of embedded browsers, session expiration and account identity remain unqualified. Pending form/visual effects still require their original receipt and document-recovery rules; this request cannot rebase them or discard uncertainty.

The planner can still request an unnecessary handoff when an optional account entry is present. Native metadata cannot prove that the user's goal requires authentication; that semantic judgment needs model/host qualification and clearer task/account prerequisites. Extend support from measured failures while keeping the manual control boundary intact.

Continue the [repair checklist](../../../TODO.md), including durable goal/effect recovery, full result verification and remaining source-policy gates. Keep real travel/concert/movie tests, model evaluation, GPU work and resource measurements deferred to their authorized stage. The installed app remains unchanged.

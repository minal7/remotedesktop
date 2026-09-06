# Retain browser evidence through visual approval

Parent source: `ddc9947`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles gap

Approval authorizes an action against the state the user reviewed. It cannot authorize an invisible replacement destination or a newly displayed authentication form. The ordinary semantic loop already revalidated owned-browser evidence, but visual approval left that loop: the host posted the approved action before asking the executor to continue. Revalidating only inside that continuation would happen after the effect. The previous host check compared native target and pixel fingerprints, which cannot detect every DOM or destination change.

## Source repair

The visual approval continuation now retains the exact document-bound browser snapshot used to propose the action. Before publishing a card, the executor completes its asynchronous OCR work, validates that same browser snapshot, and rechecks native planning state. Drift consumes the existing bounded retry budget rather than publishing stale authority.

The host rejects evidence belonging to another task before preparing the approval card. When the user approves, the host validates the retained snapshot before dispatch, then checks native target/pixel fingerprints again after the asynchronous browser read. It does not replace the old snapshot with a new read and treat that as the same approval. Changed document, page or presentation state consumes the old continuation and enters the existing fresh-planning path with the original trusted prompt; a consequential replacement action needs a new card.

An authentication challenge at this boundary cancels the pending continuation and invokes the existing visible user-control handoff. Explicit Resume is still required. The original task is retained, browser ownership is reacquired through the existing handback path, and a fresh proposal cannot reuse the old approval. Removing a password field or closing a provider window is not itself login-success proof.

The existing input-attempt marker now begins immediately before dispatch, after browser and native validation. Pausing during a browser read therefore cannot be classified as a possibly posted input merely because the user had approved. Existing partial-delivery handling remains responsible for interruption after dispatch begins. The private dispatch method requires its caller to supply both the optional browser binding and the effect-boundary callback explicitly.

The snapshot stays process-local. It is not added to phone payloads, approval messages, model prompts or durable records. Token equality includes the browser binding, so preserving the nonce and task ID while discarding that binding does not preserve the continuation. Standard and debug descriptions report only whether the token is browser-bound.

## Prepared regression coverage

Five new methods cover:

1. A link destination changes or the document root is replaced under an unchanged native/pixel fingerprint while approval is pending. No input is posted; only a fresh card can proceed, and replaying the consumed response cannot approve the replacement. The fixture also checks that the original prompt and page load are retained and opaque destinations do not enter outgoing messages.
2. A password form appears after the card. Approval hands control to the user before input. Removing the challenge followed by explicit, correctly versioned Resume produces a new card and a single approved input.
3. User takeover occurs during the final browser validation. The token is cancelled without input or a message claiming input may have occurred.
4. A continuation carries another task's browser evidence. The host rejects it before preparing a native target or presenting a card.
5. The production visual executor proposes Return on a controlled compose page. Its continuation retains the page evidence; a token with the same nonce/task and a stripped binding is rejected. Debug formatting omits the retained page's private values and destinations.

The current default source inventory selects **620** methods. The [focused inventory](browser-approval-page-inventory.json) selects **102**, including the existing page-reader, handoff, target-change, partial-input and one-shot-continuation cases. Source inventory checks, syntax-only parsing of six changed Swift files and `git diff --check` pass. No assertions ran. These fixtures use controlled WebKit pages and substituted action delivery; later execution is required, and they do not qualify actual keyboard delivery, provider behavior or natural-language model quality.

## Remaining repair sequence

1. Add a bounded, explicitly untrusted page-planning projection and whole-browser task requirements. The model still receives its existing screen-text input; this repair does not expand accepted travel, concert or movie requests.
2. Implement document-bound links, navigation, search submission, date/location/select controls and result requirements, with independent effect verification and selected public source links.
3. Carry remaining-goal state and attempted/verified/uncertain effects through login, approval, clarification and restart. This process-local pre-dispatch binding is not a durable action receipt or proof that the whole task completed. Other approval paths and non-owned browsers retain their existing contracts.
4. Account for observation limits. The bounded page projection omits form values and unsupported embedded content, and it is not an exhaustive page digest. Web content can also change after an asynchronous read returns; a later atomic DOM-target operation or independently verified effect is still needed. Keep native/text revalidation and cancellation checks at actual dispatch boundaries.
5. Compile and run the prepared composition when authorized, then qualify visible account handoff and actual browsing results. Keep real-website tests deferred until the user's explicit permission. The 8 GB and fan-load requirements remain unqualified and are reserved for the later performance phase.

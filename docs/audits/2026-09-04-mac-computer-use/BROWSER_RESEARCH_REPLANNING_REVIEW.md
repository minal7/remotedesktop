# Refresh an unsent research link after login without replacing the task

Date: 2026-09-07. Parent source: bf50882. This checkpoint adds source-level replanning of a retained result-link stage after explicit login handback. **The production general research driver and complete verified answers remain unfinished.**

## First-principles finding

A page can change while the user logs in. A link selected before that change may no longer be valid. Keeping the old target forever strands the task; replacing it without checking whether its request started can repeat an effect. A changed page is evidence that the selection needs review, not evidence that the earlier action never happened.

The replacement must therefore satisfy two independent conditions: the durable journal remains unattempted and the actual browser has no native attempt for the same operation. Those checks must precede fresh reading and selection. The original goal, operation identity and browser ownership must survive the replacement. A new selection must not create a new operation namespace that bypasses an unresolved attempt.

The earlier navigation facade returned the original target when an attempt prevented refresh. Target equality cannot tell a caller whether refresh was allowed: a valid fresh selection can have the same target. The new typed outcome makes that distinction explicit.

## Implemented source path

`replanUnsentObservedDestination` reports either a committed refreshed target, a retained target requiring reconciliation, or no selection. The existing refresh API remains a compatibility wrapper for explicit workflow callers. The same durable identity validation, native session validation and execution lease surround preparation, target validation and binding replacement. Durable attempted, uncertain or verified status, or a native attempt without a receipt, prevents fresh preparation. A second native-attempt check precedes the write. Replanning never calls navigation.

The retained research navigation component exposes this boundary for its pending stage. It keeps the original root, goal revision and operation ID, requires a current source-bound candidate and selected link, and prepares the destination through native evidence. A choice that aliases an earlier completed selection is rejected before it can overwrite completed-stage bookkeeping. Missing or invalid replacements leave the pending stage intact. An attempted stage returns `requiresReconciliation`; only the existing receipt recovery path can resolve it.

The research owner supplies a fresh current-page reading only inside that lease. Its selection callback receives the complete canonical goal and the newly bound candidate batch. Existing authentication checks, page revalidation, cancellation, operation serialization and same-session ownership apply. A paused owner cannot replan before explicit handback. The callback must select for the user's whole goal; production code does not select the first candidate automatically.

The owner clears its speculative candidate cache when replanning begins. A successful replacement updates the retained stage but does not open it. A later explicit pending-navigation continuation uses the saved replacement and the original operation ID. Ordinary replacement planning and question handling remain blocked while the stage is unresolved.

## Persistence and interruption ordering

Pause can arrive after the replacement has been written but before the caller receives it. Checking cancellation before updating the retained target would leave the old in-memory target paired with the new journal binding. The research navigation component therefore retains a confirmed replacement before surfacing late cancellation. The caller still observes cancellation and the action gate stays paused; later explicit handback can continue the matching target.

Stop retires the owner and clears pending state. A late successful replacement cannot repopulate that state, and the retired owner cannot resume or replan. The journal remains a fact about the operation, not permission to revive it. If replacement persistence throws, no new target is published. A write error after rename can leave an ambiguous on-disk replacement; an old in-memory target then fails identity checks rather than gaining authority to dispatch. Automatic reconstruction after that ambiguity remains unsupported.

Cancellation while fresh reading or selection is outstanding retains the execution lease and owner operation slot until the actual child unwinds. A second runner cannot acquire the journal, and Resume cannot overlap that unfinished work.

## Prepared verification and actual checks

Five new DOM methods prepare these cases:

- A password form appearing after selection, rejected early handback, a changed URL and link after login, explicit handback, retained root/operation identity, and no request until pending navigation is resumed.
- Missing and invalid replacements, plus attempted, uncertain and verified journals without native receipts. Attempted cases must not invoke fresh reading or selection and must not reload during reconciliation.
- Pause while the result reader ignores cancellation temporarily, rejection of a competing journal lease, and retention of the operation slot until the reader returns.
- Pause and retirement injected during a replacement write: keep a matching saved target through Pause, never revive a retired owner, and do not navigate during replanning.
- Rejection of an earlier completed selection as the replacement for a distinct pending stage, with both journal identities and the original stage sequence retained.

The [focused source inventory](browser-research-replanning-inventory.json) selects **107** methods: the preceding 97 research/navigation cases, five new cases, and five existing native unsent-refresh cases. The default source inventory selects **814**, five more than the parent. All changed Swift files were already registered in the Xcode target; no new source registration or build setting is needed.

Four Swift files pass syntax-only parsing and two new fixture scripts pass `node --check`. Both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, app launches, model inference, browser execution or computer-use activity ran.** These source checks do not establish that the prepared cases pass. The installed app and runtime/model assets are unchanged.

## Remaining repair sequence

1. Connect the production research action planner and continuation driver to the retained owner. Use the typed reconciliation outcome before selecting another action, including after login. This callable component is not yet the ordinary natural-language research route.
2. Verify action relevance against the complete user request, including prohibitions and accepted answers. A current source-bound link does not prove that it advances the task. No semantic equivalence between old and fresh link choices is claimed here.
3. Extend the ordered action ledger beyond result links to initial website/search selection, forms, dates, choices and further navigation. Keep attempted effects subject to receipt reconciliation across every action kind.
4. Verify source-associated offers, dates, availability, prices/fees and public links across pages before producing a complete answer. Navigation receipts and candidate readings are intermediate evidence.
5. After explicit permission, compile and execute controlled owner/host/model cases, then qualify real travel, concert and movie scenarios with account-login takeover and explicit handback. Performance optimization and 8 GB/thermal qualification remain deferred.

Related checkpoints: [research navigation](BROWSER_RESEARCH_NAVIGATION_REVIEW.md), [native unsent replanning](BROWSER_UNSENT_REPLANNING_REVIEW.md), [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md), [question transport](BROWSER_CLARIFICATION_TRANSPORT_REVIEW.md) and [question proposals](BROWSER_QUESTION_PROPOSAL_REVIEW.md).

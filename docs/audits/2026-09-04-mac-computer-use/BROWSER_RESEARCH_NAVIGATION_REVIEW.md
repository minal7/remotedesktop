# Retain discovered result-link navigation under the research root

Date: 2026-09-07. Parent source: 1b442b1. This checkpoint connects source-bound result candidates to retained, journaled link navigation. **The ordinary production research route, complete action planner and verified research answers remain unfinished.**

## First-principles finding

A research task discovers its next page after reading the current one. The explicit workflow driver can precompile all stages, but a research driver cannot know every result link before opening a site. It must retain each chosen navigation independently of later model decisions, clarification message IDs and login redirects. Otherwise, retrying the same action can allocate a new effect identity and send another request.

The parent research owner retained goal interpretations and candidate readings, while observed navigation already had durable attempt/receipt handling. There was no boundary connecting a selected candidate link to that journal while retaining the chosen stage through interruption. A candidate's source binding also did not itself provide a callable native navigation target.

## Implemented source path

`prepareResultLinkNavigation` requires an actual candidate ID and one of that candidate's selected link IDs. Unselected, global, foreign and invented links cannot be substituted through this entry. It validates the complete candidate batch against the current goal and actual browser evidence, then uses the existing native link preparation. Exact destinations stay in native evidence; the caller supplies neither a URL nor replacement page authority. Destination changes and authentication remain subject to native revalidation.

`ComputerUseBrowserResearchNavigation` retains the chosen selection, prepared target and stable operation ID. The operation namespace uses the original root, root digest and link-stage ordinal, excluding the answer ID, current page and payload. A failed or paused pending stage keeps that identity. A different selection cannot replace it. The existing observed-navigation facade persists the attempt before dispatch, reconciles native receipts and refuses to replay an uncertain action without a receipt.

Completed selections retain their original target/operation binding. Calling the same selection again obtains only its historical navigation receipt through the existing journal path. That receipt does not prove that its destination is still the current page or that the research task is complete. Distinct current-page selections advance the sequence; clarification answers do not reset it. Retention is bounded to 32 link stages. This is a link-stage sequence, not yet the complete ordered ledger for all research actions.

The research owner exposes candidate-link opening and explicit pending-navigation continuation within its existing serialized operation/cancellation boundary. Navigation invalidates the speculative candidate cache. A pending stage blocks fresh interpretation, candidate reads and question issuance/consumption, so new planning or an answer cannot erase unresolved action state. Pause retains the stage for explicit same-session handback; retirement discards in-memory choices without deleting durable effect journals. The production research preparation entry now supplies this navigation component using the same owned browser and the existing private journal directory.

No new root owner or model worker is allocated for a navigation retry. Recreating in-memory state is not supported restart recovery: the existing journals still bind the old operation/payload, and a missing browser receipt cannot become permission to repeat it.

## Prepared verification and actual checks

Five new DOM methods cover:

- Selected-candidate/link admission, changed goal, invisible destination changes and preparation without a request.
- One confirmed navigation, exact receipt replay, candidate-cache invalidation, durable root identity and retirement.
- Pause after target preparation but before dispatch, explicit handback to the retained stage, and a simulated durable attempt without a native receipt that must remain uncertain without loading.
- Distinct navigation stages across an exact clarification answer, preserving the original root/clock while the answer execution ID changes. The controlled page deliberately revisits the same URL under different observed page instances.
- Failure to create journal storage before any load, rejection of a replacement choice, and continuation of the same pending stage after storage becomes available.

The [focused source inventory](browser-research-navigation-inventory.json) selects **97** methods, including prior navigation-journal, research-owner, candidate, question, host and phone cases. The default inventory selects **809**, five more than the parent. The new source is registered in the Xcode target; other changed files were already registered.

Six Swift files pass syntax-only parsing, one new fixture script passes `node --check`, and project syntax, both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, app launches, model inference, browser execution or computer-use activity ran.** The installed app is unchanged. Prepared fixture behavior is not real-site qualification.

## Remaining repair sequence

1. Connect a production research action planner and driver using the complete retained goal, current page and verified prior actions. Implement initial website/search selection, form/date/choice arguments, further navigation and explicit stopping criteria. This checkpoint supplies result-link execution only; ordinary natural-language requests do not yet invoke a general research driver.
2. Bind a selected action to the user's intended research work. Candidate grouping/link selection establishes source provenance, not semantic relevance or permission for unrelated work. Keep page content outside user authority and preserve the task's prohibitions and requested outcomes through action selection.
3. Reconcile every pending child before choosing another step. Add reviewed refresh/reselection for a proven-unsent candidate link after a login or page change, using the existing durable-and-native no-attempt checks. This boundary currently retains the old target and blocks when it is stale; it does not automatically infer that a new link is equivalent. Attempted or uncertain actions must never gain that refresh permission.
4. Extend the ordered research state to remaining action kinds and complete post-login work, then verify source-associated offers, dates, availability, prices/fees, public links and every result condition. A successful link load or source-bound candidate is not task completion.
5. After explicit permission, compile and execute controlled owner/navigation/host/model cases and then qualify the retained real-site travel, concert and movie scenarios. Keep performance work deferred; no 8 GB or thermal qualification has been established.

Related checkpoints: [question proposals](BROWSER_QUESTION_PROPOSAL_REVIEW.md), [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md), [candidate binding](BROWSER_RESULT_CANDIDATES_REVIEW.md), [observed navigation journal](BROWSER_NAVIGATION_JOURNAL_REVIEW.md) and [unsent replanning](BROWSER_UNSENT_REPLANNING_REVIEW.md).

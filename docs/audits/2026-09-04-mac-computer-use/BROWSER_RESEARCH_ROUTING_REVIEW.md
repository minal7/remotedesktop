# Keep browser research on its retained capability route

Date: 2026-09-07. Parent source: 9392fda. This checkpoint adds browser research admission and continuation to the production capability wrapper and routes controlled host/phone cases through it. **The default loader does not yet supply a research driver. General natural-language website research remains unfinished and unqualified.**

## First-principles finding

An answer to a question about a research task is a revision of that task, not an unrelated new request. Resume after login likewise continues the earlier work. If the outer capability executor forgets which component owns that work, it can ask a different planner to execute the answer alone, restart admission or enter desktop fallback after an uncertain browser action.

The parent already had a retained research owner and host transport for scoped answers. Its host and phone cases used a fixture executor that implemented research continuation directly. The production `ComputerUseCapabilityExecutor` supported native and desktop routes only and did not implement the research continuation protocol. Those fixtures therefore did not exercise the wrapper that must retain the research route in the shipped composition.

A second issue appears if admission looks up an owner only after a driver returns. An owner may have been prepared and then closed or replaced during an await. Its absence on return cannot prove that admission never happened or that fallback is permitted.

## Implemented source path

`ComputerUseBrowserResearchExecuting` defines initial admission and inherits the typed continuation interface. Initial admission receives the complete current user request, without assistant history or a rewritten model prompt. A nil result means a no-effect decline before retaining an owner. A prepared task must use its retained owner for later execution and cannot decline into another capability.

The capability wrapper accepts an optional research driver. Complete explicit browser workflows and native editing retain their existing precedence. After a native no-effect decline, a configured research driver is selected before desktop fallback. Native success or failure cannot enter research. The wrapper commits the research route before awaiting admission; errors and cancellation do not reset it to native or desktop.

Host tools now expose a scoped admission observer. Preparation reports the actual research owner synchronously, before returning it to the driver. The wrapper records that object and its canonical input immediately. The observer remains installed until admission actually returns and rejects overlapping admission scopes. Closing or replacing the browser later cannot erase the wrapper's record. A lost owner blocks continuation and readmission. Only an admission that returned nil without preparing an owner can enter desktop fallback.

Resume finds the same host-held object and delegates through `continueBrowserResearch`. The wrapper checks the original request, canonical revision and current execution ID. An accepted answer can advance the retained input by exactly one sealed clarification turn; a repeated Resume uses the already accepted revision. Foreign objects, unrelated IDs, skipped revisions and replacement roots are rejected. A new ordinary task retires the previous retained owner. The wrapper holds its execution slot until the actual delegate returns, including when cancellation is temporarily ignored.

The owner supplies a read-only continuation check for its revision, local control state, retirement, operation exclusion and pending question. Browser session/page/effect checks remain in the owner's actual operations. The wrapper checks state before continuation and before returning a result, so a late result cannot escape Pause or retirement.

A research question must match the retained owner's current typed question proposal. Raw clarification strings and unrelated visual/MCP approval continuations cannot leave this route. Other routes cannot emit a browser-research question merely because the wrapper now implements the continuation protocol. Terminal result verification remains the research driver's responsibility: this routing change does not turn a navigation receipt or candidate reading into a verified research answer.

## Prepared verification and actual checks

Seven new capability methods prepare:

- Complete current-user authority, retained owner/clock, ordinary Resume, one exact Unicode clarification answer and repeated continuation without appending it again.
- Desktop fallback after a no-effect decline, and rejection of a decline after ownership was retained.
- Admission errors before and after preparation, without rerunning native admission or losing a prepared owner.
- Cancellation, Pause and retirement while a delegate holds the route, rejection of competing execution and suppression of late results.
- Prepared owners disappearing through close or replacement, including a subsequent retry that must not re-admit or fall back.
- Foreign owner/ID rejection, skipped answer revisions, retirement on a new root and rejection of the old continuation.
- Missing owners, foreign or unscoped questions, incompatible approval results and research questions emitted from native/desktop routes.

The existing native-success and native-error methods also select a research delegate that must not be invoked. Four existing host methods and the actual-client/host browser-question composition now wrap their controlled research driver in `ComputerUseCapabilityExecutor`. Their scenarios retain exact answers, durable replay, local Pause, account-login handback, persistence failure and controller/Stop/disconnect retirement. They still use controlled proposals and do not perform general website research.

The [focused source inventory](browser-research-routing-inventory.json) selects **123** methods, including the preceding research cases and the complete capability test class. The default source inventory selects **821**, seven more than the parent. Eight changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. All changed Swift files were already registered in the Xcode target.

**No typechecking, test assertions, builds, model inference, app launches, browser execution or computer-use activity ran.** Source selection and parsing are not evidence that these cases execute successfully. No model/runtime assets or installed app were changed.

## Remaining repair sequence

1. Implement the concrete research driver and its local action planner, then supply that driver from the default capability loader. The optional route is available in source; no placeholder driver is installed or advertised as working browsing.
2. Make whole-goal admission, accepted-answer semantics and action relevance explicit. A no-effect decline must happen before ownership/effects. Preserve every condition and prohibition while choosing initial search/site navigation, forms, dates, choices and result links.
3. Use the retained owner's pending-navigation/replanning boundary before selecting another action after login. Extend the ordered ledger beyond links and reconcile attempted effects without replay.
4. Accumulate and verify source-associated offers, dates, availability, prices/fees, public links and complete result predicates before returning an answer. The routing interface deliberately supplies no shortcut to that evidence.
5. After explicit permission, compile and execute controlled driver/host/model cases, then qualify real travel, concert and movie workflows with manual account login and explicit handback. Performance and 8 GB/thermal qualification remain deferred.

Related checkpoints: [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md), [research navigation](BROWSER_RESEARCH_NAVIGATION_REVIEW.md), [question transport](BROWSER_CLARIFICATION_TRANSPORT_REVIEW.md), [question proposals](BROWSER_QUESTION_PROPOSAL_REVIEW.md) and [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md).

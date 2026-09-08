# Select a result link with the local model under the retained goal

Parent source: `aece8c4`. This checkpoint implements a local link-selection adapter and connects it to the research planning interface. It is source work with prepared regression coverage, not model or installed-app qualification.

## First-principles findings

The concrete navigation driver accepted a planning policy, but only a controlled fixture supplied link choices. A result reader identifies possible groups and their text/link references; that is not a decision about which page to read next. Automatically opening the first grouped result would confuse document order with relevance and could discard source, date, location, price or other constraints.

The selector needs the original request and accepted answers, the actual bounded reading, its interpretations and omissions, and confirmed navigation history. Its reply must name a candidate/link pair from that exact reading. A stale reply cannot be made current by reusing the same visible label or returning no selection. A model proposal still cannot establish destination compliance, offer semantics, permission for commitments or task completion.

## Source implementation

`ComputerUseBrowserLinkSelectionInput` is constructed from native-bound result candidates. It checks the current goal/root and a bounded, duplicate-free history from the same research root. The candidates now retain the original reading projection used by the result planner. The link selector receives that complete bounded projection, including surrounding records and omission flags; it does not rebuild a shorter page or copy native destination URLs and account/session identity into model context.

The context contains the complete original goal, separately accepted answers and fixed date/time-zone context. Candidate entries contain numeric indexes, observed container/field/link references, visible unclassified text IDs and unprojected record counts. History exposes only visit order/kind and whether each visit used the current goal revision. Private candidate, browser and operation identities are bound in the input but omitted from the model message. Confirmed visits now retain their root digest so another task's history cannot be substituted.

`ComputerUseBrowserLinkProposal` decodes a closed two-field response: a candidate index and one of that candidate's selected observed link IDs. The sole no-selection representation is index `-1` with an empty link. Unknown/duplicate fields, malformed types, fractional/out-of-range indexes, cross-candidate links, unobserved links and oversized output are rejected. Both selected and no-selection replies retain the exact immutable input and reject consumption under a changed goal, native page/snapshot, candidate batch or history.

`ComputerUseLocalBrowserLinkPlanner` uses the existing authenticated loopback transport and strict response-envelope decoder. It counts the exact serialized request before completion, checks cancellation around token counting and response receipt, and rejects overflow without shortening the request or reading. The existing 4096-token context, 1024-token output reserve, 64-token framing reserve, deterministic sampling, disabled prompt cache and 30-second request timeout remain in use. When no candidate exposes a selectable link, it returns input-bound no selection without token counting or inference; this does not claim that the website has no results.

The runtime adapter uses the same verified native-text model worker as goal/query/result planning. It checks the empty-choice case before activation. Otherwise it retains the existing model access lease across exact token counting, completion and strict decoding, with resource admission, endpoint identity checks and endpoint-scoped cancellation/cleanup. It does not allocate another worker or change the installed model. Actual lifecycle behavior for this new entry point remains unqualified.

`ComputerUseModelBrowserResearchPlanning` connects this adapter to the concrete driver. Host provider policy is injected independently and cannot be supplied by a model-authored URL. The bridge binds the current goal/candidates/history, awaits the proposal, checks cancellation and consumes it only against that exact input. The owner's serialized planning operation still revalidates the actual page after selection. Native target binding, durable attempt admission and receipt recovery remain separate checks before navigation.

The prompt asks for a relevant next reading while retaining all constraints and treating page text and grouping labels as untrusted data. It permits no selection and distinguishes navigation from a verified offer/answer. These instructions do not prove semantic correctness or enforce source restrictions at the destination boundary; those remain explicit implementation/qualification work.

## Prepared regression coverage

Seven new methods cover:

- The complete clarified request and original clock in a separate goal object, intact bounded page context, observed candidate references, private native/transport identifiers omitted from model context, and the fixed authenticated local request contract.
- Valid choices for each of two observed candidates, a valid no-selection result, cross-candidate/unobserved links, duplicate/unknown fields, invalid types, multiple outputs and byte limits. Unclassified fee text remains available as page evidence.
- Changed goal, fresh snapshot, another native browser binding, different history, duplicate visits and a foreign research root rejecting old input/proposal use, without opening result links.
- Exact token-count/completion request identity, zero/negative/overflow counts, the 3008-token input boundary, and cancellation after counting or completion.
- Malformed, foreign-model, unfinished, wrong-role, tool-call, refusal and duplicate-field envelopes; an empty selectable-link set invokes no transport call.
- The actual capability executor and concrete research driver using the local model adapter with a controlled transport: a specified second result is opened, the first result is not, and a later no-selection result remains user intervention rather than a complete answer.
- A stale no-selection reply rejected by the planning bridge and Pause during a suspended model proposal retaining the owner operation until actual unwind; explicit Resume preserves the initial search.

The native loopback fixture is shared with the preceding driver cases. Its new optional result/link planners and extra card let these cases compose production adapters without claiming model quality from predetermined fixture responses. The seven methods are prepared but unexecuted.

## Checks actually performed

Six changed Swift files passed syntax-only parsing. Xcode project registration passed `plutil -lint`. The [focused source inventory](browser-link-planner-inventory.json) selects 207 methods and the default selects 890, seven more than the parent. Source identifiers and whitespace checks pass; these counts are not passing assertions. The new production and test files are registered in their Xcode targets. No new JavaScript was introduced.

**No typechecking, builds, tests/assertions, model inference, app launches, browser/computer-use activity or live website E2E ran.** Installed app, runtime/model assets and held-out qualification sets remain unchanged. The desktop's previous SSH timeout remains unresolved; no remote model work ran in this checkpoint.

## Remaining repair sequence

1. Implement host provider/site policy from the complete request. Enforce source restrictions against actual native destinations, including redirects, independently of a model-selected link label. Resolve source ambiguity through retained task clarification/control rather than silently broadening it.
2. Compose the goal/query/result/link adapters, provider policy and concrete driver in the default loader. The current loader still omits research, so this checkpoint does not enable normal installed-app research.
3. Extend navigation beyond candidate links: general site search, forms, dates, choices and additional pages need a complete ordered action ledger and recovery after process restart or lost browser state.
4. Add semantic whole-goal/answer checks and source-associated offer evidence across pages: relevance, dates, locations, availability, quantity, prices/fees, public links and complete answers. The compact history here lacks prior page contents and cannot establish semantic progress or prevent every navigation loop.
5. Qualify this exact prompt, decoder and runtime composition with real model responses and controlled interruption/login cases once Mac test execution is authorized. Preserve the held-out sets. Use measured model failures to decide whether replacement or authorized desktop adaptation is needed; source/ownership bugs are not evidence that a model needs pruning.
6. Keep real travel/concert/movie E2E paused pending later explicit permission. Performance optimization and 8 GB/thermal qualification remain the later phase requested by the user.

Dependencies: [research driver](BROWSER_RESEARCH_DRIVER_REVIEW.md), [candidate source binding](BROWSER_RESULT_CANDIDATES_REVIEW.md), [result structure](BROWSER_RESULT_STRUCTURE_REVIEW.md), [query planner](BROWSER_SEARCH_PLANNING_REVIEW.md), [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md) and [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md).

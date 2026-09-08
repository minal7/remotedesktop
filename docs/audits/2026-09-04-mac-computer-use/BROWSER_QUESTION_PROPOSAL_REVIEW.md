# Connect browser goal interpretation to scoped host questions

Date: 2026-09-07. Parent source: 86948ca. This checkpoint repairs the planner/owner question contract and prepares regression coverage. It does not add or qualify the missing production research action driver.

## Finding from first principles

The original goal and a clarification answer must meet at the same task owner. The owner also needs to know which missing detail a question concerns. A free-form string such as “Where and when?” provides neither an unambiguous topic nor a source scope. Parsing that prose again would add another interpretation step and could confuse account-login instructions with task questions.

The parent goal planner returned an arbitrary question string, while the host transport required a typed topic and requirement IDs. The prepared host executor supplied those fields itself. Thus, passing its transport cases would not establish that a real planner could select a question through the same contract. The production routing review found this missing connection before a general research driver could use it.

## Repair

The local goal response schema is now `browser_goal_proposal_v3`. Its `question` field is a closed object containing a topic and indices into the proposal's top-level requirements array. For clarification, the decoder requires one of the existing nine host topics and one to eight distinct, increasing, in-range indices. It maps those indices to source-bound requirement IDs only after exact coverage of every user turn has passed. Repeated text occurrences remain different requirements.

Question scope may include related outcomes, or conditions/clarification fragments with matching fields. Prohibitions, ordering and unsupported work cannot become question scope. The shared topic definition now supplies both the accepted fields and the model's topic/field guidance. For research or unsupported disposition, the only valid question is topic `none` with no indices. Free text, credential topics, unknown fields, booleans/fractional indices, duplicates, reversed scope and mixed dispositions are rejected. The host decoder enforces relationships that the bounded generation schema alone does not prove.

The proposal stores a typed question selection and includes its topic/scope in the versioned proposal digest. It holds no model-authored display question. `ComputerUseBrowserResearchTask.proposedQuestionRequest()` converts only its current retained interpretation into the existing host request type. It does not infer again, issue a reference, claim a browser or perform an action. Pending questions, missing interpretations, accepted new revisions, Pause and retirement retain their existing lifecycle restrictions. The transport still independently binds the actual owner, revision, controller/session, expiry and browser context before accepting an answer.

The shared host/phone fixture now obtains its question request from the decoded interpretation through this owner entry, instead of constructing the request directly. Explicit host-originated questions remain available for future compilers that discover missing details independently of the model; they still pass the existing scope checks.

## Prepared verification

Four new goal-planner methods cover all supported topics and matching source scopes, distinct repeated occurrences, the final allowed requirement and eight-reference bound, malformed/free-text/credential questions, invalid role/field scope and contradictory dispositions. One of those methods composes the actual local planner request/response decoder, retained owner, host reference transport and strict answer-wire decoder through two exact answers using controlled responses. It checks the immutable original goal/clock, current answer correlation and stale-proposal rejection. No inference or browsing is part of that prepared case.

One new owner method checks conversion before interpretation, cached access without another model call, pending-question exclusion, answer revision changes, no question on research disposition, Pause/Resume and retirement. Existing schema assertions, raw credential-question rejection and goal/scalar/result/host fixture responses were updated to the new contract. Existing host and actual-client composition methods now exercise the owner conversion when choosing their controlled questions.

The [focused source inventory](browser-question-proposal-inventory.json) selects **79** methods. The default inventory selects **804**, five more than the parent. All changed files are already registered in the Xcode project. Nine changed Swift files pass syntax-only parsing; both source inventories and whitespace checks pass. **No typechecking, test assertions, builds, app launches, model inference, browser execution or computer-use activity ran.** The installed app remains unchanged.

## Remaining work

1. Implement and connect the production research driver and capability continuation. This change supplies the typed question proposal it needs; it does not make that driver exist or make an ordinary ticket request use this owner.
2. Complete whole-goal and answer semantics. Valid source coverage and topic/field matching do not prove that a question is necessary or correctly associated. A model can still select the wrong valid topic, misclassify a fragment or fail to reconcile a later answer with an earlier condition. Missing details outside the current nine topics remain unsupported; broader clarification needs an explicit extension.
3. Drive journaled browser actions and verify complete results, including task conditions, offer associations, dates, availability, prices/fees, source links and remaining work after login. A typed question is not evidence that any research outcome was achieved.
4. Qualify the new v3 prompt/schema and decoder together after explicit permission. Old v2 string responses intentionally fail admission; there is no compatibility fallback that recreates question meaning from prose. No historical model result qualifies the changed prompt. Confirm actual runtime schema handling and full-input token budgets through the installed composition before real-site travel/concert/movie scenarios. Keep 8 GB and thermal measurements for the later performance phase.

Related checkpoints: [browser answer transport](BROWSER_CLARIFICATION_TRANSPORT_REVIEW.md), [research owner](BROWSER_RESEARCH_OWNER_REVIEW.md), [original goal proposals](BROWSER_GOAL_PROPOSAL_REVIEW.md) and [scoped questions](BROWSER_GOAL_CLARIFICATION_REVIEW.md).

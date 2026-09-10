# Longer retained browser conversations

Source repair; execution pending. This follows the [whole-party correction work](BROWSER_PARTY_REPLACEMENT_REVIEW.md). No build, typecheck, assertion, browser, app, model, login or SSH execution occurred.

## First-principles finding

A request can need several independent details before research begins. Origin, destination, date, party size, location and time already require six answers when asked separately. The browser input previously allowed only four user turns including the original request: three answers. That stopped a valid clarification sequence before any question of model competence, website support or available memory arose. Corrections consumed the same small allowance.

Increasing retention alone does not make a small model understand a longer conversation. The complete source must still fit its actual token budget, and the planner must retain every obligation. Source review also found that the goal planner's instructions had accumulated form-input and result-graph details, including names of context fields absent from this planner's input. Those instructions consumed space and described work this stage could not perform.

At the eventual conversation limit, another proposed question also needs an honest outcome. Failing to issue its reference must not turn the last answer into a new request, erase the earlier answers or report completion.

## Native retention and limits

[Browser goal input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) now permits 16 user turns: the original request plus 15 accepted answers. This is a bounded engineering allowance for several details and corrections, not a measured model limit or a promise that every 16-turn conversation will fit.

The existing independent limits remain: 32 KiB of total user UTF-8 source and 8 KiB per accepted browser answer. Native input exposes the remaining answer count and next-answer byte limit. Appending an answer and [issuing a question](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) use that same capacity. Empty, oversized, duplicate-ID, foreign-root or wrong-reference answers still do not consume the pending reference. A byte-full request can have unused turn capacity and still cannot accept another answer.

No source is summarized, trimmed or replaced. Every accepted answer retains its question scope, exact bytes, original task identity, prior interpretation and its own date context. The original clock and all accepted prefixes remain available. Login handoff remains a separate manual-control operation rather than a credential clarification answer. Existing work and navigation allowances are unchanged and are not reset by these additional answers.

## Planner and intervention behavior

The [goal planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) instructions now focus on complete source interpretation, roles and fields, literal hints, date clocks, source policies and typed clarification/correction scope. Form verification and result-assessment graph instructions remain in their relevant planners. The response schema and structured user context are unchanged.

The goal planner still uses a 4,096-token context, reserves 1,024 output tokens and 64 framing tokens, and asks the transport for the exact count of the entire request before inference. A longer native conversation cannot override that gate. Nothing selects a larger model, context window or output allowance automatically.

All six [driver question paths](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) now convert a question proposed after native capacity exhaustion into a nonterminal intervention. The [host manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) applies the same behavior when another executor returns a question at the limit. It pauses the retained task without issuing a new answer reference or reporting task completion. The guidance explains that the original request and previous answers remain in the task and that Resume does not reset the limit.

Capacity exhaustion does not prevent research that already has all its details: the check applies when another question is requested. It does not independently cancel an otherwise justified form action, reading or answer. Manual continuation does not establish success or grant new automation authority.

## Authored verification, unrun

Seven new methods are registered:

- Four [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) specify six travel details with an unchanged budget and prohibition, restoration of every accepted prefix, rejection of omitted/reordered/rewritten source, full-request model token admission, and separate Unicode byte/reply/turn bounds. The existing boundary method now exercises the full native turn allowance and checks that exhausted capacity cannot issue another question.
- Two [driver methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchDriverTests.swift) specify research beginning after six short answers and preservation of the full request at the 15-answer limit. Resume must retain that exhausted conversation without browser navigation or readmission of the last answer as a new task.
- One [host-manager method](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) sends the full sequence through structured wire references, then uses a controlled executor that asks one question too many. The host must pause the original owner and keep all answers through a subsequent Resume. The shared [question fixture](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) keeps its prior two-answer behavior by default.

Eight changed Swift files pass parse-only checks. Active inventories select 1835 default / 1152 focused methods, with seven additions and no removals. These are syntax and source-registration checks only. The authored assertions, wire deliveries, pauses, query counts, model tokenization and model outputs have not executed.

## Remaining repair sequence

1. Qualify real multi-answer requests against the complete prompt, schema and output budget. A shorter instruction template is not proof of better reasoning or adequate context capacity. Compare actual-model behavior before accepting the change as qualified.
2. Address the goal response's independent limits: 32 requirement rows, 512 Unicode scalars/2,048 bytes per source fragment, a 16 KiB decoded response and the 1,024-token output allowance. Some byte-admitted inputs may not be representable under those limits. Consider native source-span references or another exact-source representation; never solve this by omitting user text.
3. Define longer-conversation and context-limit recovery, deliberate task revision, and durable process recovery. The retained history remains in memory; this repair does not promise recovery after process loss. Sixteen turns is not unrestricted conversation.
4. Continue semantic corrections, shared requirements, provider-specific travel/ticket controls and source-history qualification. Global navigation-source completion remains restricted.
5. Follow the [repair checklist](../../../TODO.md) and retain the deferred travel, concert, movie and login-handoff scenarios. Actual model competence, the 8 GB Mac target and thermal behavior remain unqualified. No alternate model, RTX 3080 adaptation, distillation, pruning or SSH retry occurred here.

Live tests remain deferred until explicit permission.

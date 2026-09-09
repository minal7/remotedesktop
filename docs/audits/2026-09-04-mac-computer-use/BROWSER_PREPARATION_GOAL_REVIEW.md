# Reviewing answers while form preparation is retained

Status: source repair for goal interpretation and follow-up questions. Revised form execution remains incomplete; no runtime or model qualification is claimed.

## Failure and repair

The [retained preparation path](BROWSER_LATER_PREPARATION_RECOVERY_REVIEW.md) correctly keeps original private observations and earlier verified criteria when a clarification answer arrives. However, `interpretGoal` and `proposedQuestionRequest` rejected every pending form. The driver tried to resume the old preparation before interpreting the new answer, so the task could neither reconsider the complete request nor ask a necessary follow-up question.

Goal interpretation and effect authority are separate. An answer adds source material to the retained conversation; it does not validate a previous field selection, erase existing preservation obligations or authorize a new baseline.

[The task owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) now permits goal review alongside unstarted preparation when the current input continues its original goal. A pending execution still blocks goal review and retains its original contract. The owner continues to enforce ownership, Pause, question and navigation gates. It checks the owned page before a fresh model proposal and validates the exact current input before publishing the result. An unchanged interpretation is reused without another model request or native observation.

[The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) recognizes a retained preparation whose goal revision changed. It interprets the complete request first and can return a question bound to that current revision. All accepted answers, the root request, reference clock and time zone remain in the owner. Neither a cancelled nor foreign interpretation can replace the current one.

A fresh interpretation with no further question **does not yet resume the form**. The driver returns an intervention result and keeps the preparation. Source policy replacement, another action selection, old form execution and rediscovery remain blocked. A new form-scope review and explicit transfer of the original obligations are still required. This checkpoint removes the interpretation deadlock, not the broader form-reconciliation gap.

## Prepared coverage and validation limits

Seven added methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover multiple accepted answers with the original clock and request; driver follow-up questions before old preparation; research/unsupported interpretations retaining the old frame; unchanged-goal caching; cancellation and explicit handback; rejection during pending form execution; and rejection of a foreign goal proposal. The cases assert that interpretation does not rediscover fields, recapture readonly preservation or send another input.

Three changed Swift files passed `swiftc -frontend -parse` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,377** source methods and the [focused inventory](browser-control-state-inventory.json) selects **694**, adding seven identifiers without removing prior coverage. Documentation links and whitespace are checked. These are source checks: none of the new assertions has executed, and parsing does not establish type correctness or actual callback/model behavior.

No build, typecheck, test execution, app/browser/computer-use launch, inference, SSH retry, held-out inspection or installed-app replacement was performed. No scratch artifact was generated.

## Next repair sequence

1. Re-review the selected form under the current interpretation and source restrictions. Carry original preservation sources and retained research readings into that review; overlapping source spans are references, not proof of unchanged meaning.
2. Transfer preparation to the revised review without changing already captured values or native identities. Account explicitly for every earlier verified criterion and every original preservation obligation. Handle newly needed fields and explicitly superseded work; do not require users to abandon the full task to fit the old field set.
3. Retain revision preparation before native work, join cancelled callbacks and prevent stale proposals from consuming it. Only the completed revised input may reach the form planner and executor.
4. Continue ownership, process and login-session recovery, complete result verification, then qualify actual lightweight models and website flows when execution is authorized. The [repair TODO](../../../TODO.md) remains active.

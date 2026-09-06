# A read result cannot prove an additional action

Parent source: `353780a`. Status: source repair and regression registration only. No build, XCTest execution, model run, app launch, computer-use activity or installed-app replacement. Performance optimization and live travel/concert/movie acceptance remain deferred.

## First-principles failure

A task is complete only when every requested outcome has evidence. Successfully reading a contact proves that lookup; it says nothing about opening another application or typing into it.

The structured executor already projects answers from reviewed, typed tool results rather than trusting the planner's answer text. However, its completion check collects a set of requested read domains. Its separate consequential-mutation check recognizes only certain verb/noun pairs. Neither check represents ordinary additional actions.

Source-derived example: `Find Jordan Lee's phone number in Contacts and open Notes.` A reviewed `contacts_search` call with a matching typed result satisfies the Contacts domain. A following `TASK_COMPLETE` can then return the phone number as whole-task completion without evidence that Notes opened. The pure application-open route rejects compound requests, so it does not discharge the missing work first. This finding comes from source review, not a live reproduction.

## Source repair

Before accepting any read-only projection as task completion, the executor now rejects affirmative additional operation requests from a bounded vocabulary covering application actions, input, editing and consequential work. It uses the current trusted instruction, not conversation context or planner prose. This check rejects a completion proposal; it grants no authority to perform the named action.

The existing operation-authority parser preserves negation and question scope and masks quoted payloads. A narrow exception recognizes `open` as an adjective in contiguous inventory phrases such as `Please show all open windows`. It cannot cross conjunctions, punctuation or newlines into another command. The surrounding authority scope remains intact. Existing private-read authorization, argument validation, result projection and consequential-mutation checks remain in force.

A rejected stop signal takes the existing fallback route with the complete model context and the original trusted goal. The new tests make that fallback return a clarification, rather than inventing successful execution. This repair does not prove that the fallback can finish the task or establish complete natural-language coverage.

## Prepared regressions

Four new methods exercise the production structured executor with a scripted planner, typed MCP results and a recording fallback:

1. A valid Contacts result followed by a completion proposal while the request also asks for application, pointer, keyboard, clipboard, save or print work; separate sentences and a polite action question are included.
2. Valid Contacts reads with negated actions and a double-quoted action label, preserving supported read-only completion.
3. Conflicting model context and trusted current instructions in both directions. Only the trusted current instruction determines whether additional work remains.
4. Plain/polite open-window inventories, an action following the inventory, and a newline that must not be absorbed into the adjective exception.

The fixtures assert the actual read call and planner stop are reached, no approved call occurs, and fallback receives the correct task ID/context/current instruction where applicable. Existing private-read authority, entity matching, typed projection, compound-domain and exact Mail-approval cases accompany them in the focused inventory. These fixtures have not been compiled or executed.

## Verification

Source inventory checks match **556 default** and **11 focused** method identifiers. `git diff --check` passes. All changed Swift files were already in the project. See [the focused inventory](structured-read-completion-inventory.json). These checks establish source registration and whitespace consistency only.

## Remaining repairs, in dependency order

1. **Compile complete structured goals.** Replace the domain set as completion authority with explicit read/action/report obligations in the shared task contract. Preserve every entity, requested field, constraint and dependency; reject or clarify a residual clause that cannot be represented. The new vocabulary is a bounded rejection rule. It cannot prove arbitrary paraphrases, conditionals, informational subquestions, other languages or all quoted-text forms are covered. Do not keep expanding keyword lists as a substitute for the contract.
2. **Bind every requested entity.** `Find Jordan Lee and Avery Chen in Contacts` currently collapses to one Contacts domain. Evidence for Jordan alone can satisfy that domain. Compile both entities and require independently matching results (or an explicit verified absence for each). Do not infer completeness by counting calls, accepting any matching substring, or erasing common words from names. Audit multi-list Reminders and other read scopes separately.
3. **Separate action confirmation from task completion.** `continueAfterApproval` currently returns `.completed` after one approved MCP call succeeds. Exact approval authorizes that action; it does not prove remaining reads, actions or reports. Introduce a typed action receipt and remaining-goal state, then resume/verify only unfulfilled authorized steps. A simple single-action task should still finish when its whole outcome is proven.
4. **Preserve the distinction through durable recovery.** `ComputerUseTaskLedger.ApprovedActionRecord` stores an action fingerprint and response. Host approved-action replay currently projects a stored response as `.completed`. Persist action outcome separately from whole-task outcome and remaining obligations; avoid replaying an attempted action whose effect is unknown. Preserve existing first-terminal/Stop behavior and historical evidence delivery. Do not use a confirmed action response as a whole-task recovery certificate.
5. **Compose capabilities around the same contract.** Carry verified structured read evidence into later native/visual steps without substituting a partial goal or granting read text instruction authority. Bind future entities and step-specific targets, then replace global TYPE/Return suppression with per-step receipts. Keep focus, cancellation, execution ownership and approval checks at actual effect boundaries.
6. **Qualify only when authorized.** Compile and execute focused regressions; extend controlled compound-task fixtures for multiple contacts, read-plus-action, action-plus-report, approval, Stop and restart. Later test the actual compact planner and real travel/concert/movie scenarios through the app. Record verified constraints, dates, locations, results and sources. No current source check qualifies those workflows or the 8 GB/thermal target.

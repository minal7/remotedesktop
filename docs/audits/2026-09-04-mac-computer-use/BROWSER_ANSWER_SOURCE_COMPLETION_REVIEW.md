# Verify answer-source restrictions against the reading policy

Source checkpoint: 2026-09-09. Parent: `4310a3e`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

Where evidence comes from and what that evidence proves are different questions. A source restriction should be checked against the native document origin and the policy governing its reading. A page cannot prove its own source eligibility by naming an allowed site or claiming not to use an excluded site.

The answer compiler handled every prohibition before considering source fields. Consequently, a valid answer-source exclusion such as “Do not report results from blocked.test” could never support a completed answer: it failed the separate, limited execution-prohibition branch even when the source policy had correctly excluded that site.

Simply allowing every source clause would be insufficient. The reading's permitted status described its configured policy, which could be looser than the current compiled source constraints. That status alone did not establish a match with the required answer policy. Earlier restrictions retained across an answer or resegmentation must also participate in that match.

## Source repair

[Source requirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) now provide an explicit match against the actual answer-source policy. When the goal has answer-source obligations, the policy must equal the one compiled from its complete current and retained historical origin sets. The goal revision must match, the source compilation must be resolved, and a policy must actually exist. Goals with no answer-source clause can still use additional filtering from the same goal; source permission for the actual document remains a separate check.

The compiler also identifies current requirement IDs that carry historical answer-source obligations after resegmentation. This mapping describes an additional obligation, not the complete meaning of a mixed row.

[Candidate readings](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultCandidates.swift) compare those requirements with their private retained policy. [Assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) distinguishes a missing policy, an excluded source and `sourcePolicyMismatch`. A policy mismatch can annotate a resegmented row carrying an earlier restriction; a successful match does not turn that mixed row's other work into a source fact.

Assessment context uses version 5 when it contains answer-source requirements or the new mismatch status. [Link-planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) explain that permitted document status alone cannot resolve a mismatch and that source eligibility proves no other requirement.

[Answer eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchAnswer.swift) checks policy correspondence for the entire page before considering an answer. This also covers retained restrictions hidden by a later model's field labels. An explicit answer-source requirement then needs the matched native `sourceOriginPermitted` assessment, including when its role is prohibition. The source clause remains in the rendered requirement ledger.

Host-bound literal price parameters retain their existing treatment even when a model labels their answer as a source field. Unrelated content prohibitions, offer association, scalar checks, result counts, full evidence, link selection and current answer validation keep their existing requirements. This change does not reinterpret a source fact as venue, seller, availability or task-completion evidence.

## Prepared coverage and allowed checks

Six methods were added, all authored and unrun:

- Three cases in [ResearchAnswerTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) describe a complete native/driver answer with a matched source exclusion, refusal when a permitted document was read under a looser policy, and refusal of an unrelated unresolved venue prohibition despite a matched source policy. The fixture can now include an explicit source-exclusion clause and independently configure the actual reading policy.
- Three cases in [SourceRequirementsTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourceRequirementsTests.swift) check exact compiled sets and goal identity, historical restrictions hidden by resegmentation, and additional filtering for a goal with no answer-source clause.

Seven changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1600 default / 917 focused methods: six additions each, with no removed or renamed identifiers. No JavaScript changed. These are syntax and source-inventory checks, not compilation or passing assertions. The authored driver scenarios do not qualify the live application or a local model.

## Remaining repair order

1. Navigation-source requirements need evidence about the actual navigation sequence and policy lineage. The current answer path still has separate incomplete handling: generic navigation-source conditions can pass without a complete route-history check, while navigation prohibitions remain held by the execution-prohibition branch. A permitted answer document must not be used to claim that every earlier automated visit complied.
2. Represent explicit criterion replacement throughout planning and completion. Retain old user text and action receipts while identifying the current criterion. Distinguish a user's changed intent from correction of an earlier model classification.
3. Reconcile replacement with pending effects, form purposes, preservation/read duties and source-policy installation. Completed or uncertain native work cannot be discarded through a semantic update.
4. Continue login document transitions, process/account recovery, dependent controls and independent result verification in the full [repair checklist](../../../TODO.md).
5. Live travel/concert/movie scenarios, alternate-model comparisons, desktop adaptation and the 8 GB resource target remain unqualified and deferred to execution permission. No assertions, app/browser execution, inference, SSH retry, push or installed-app replacement occurred here.

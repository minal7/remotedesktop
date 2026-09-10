# Native source references for browser goal interpretation

Source repair; execution pending. This follows the [extended-conversation repair](BROWSER_EXTENDED_CONVERSATION_REVIEW.md). No build, typecheck, assertion, browser, app, model, login or SSH execution occurred.

## First-principles finding

The host already owns the user's exact words. Requiring a small model to reproduce them adds a second transcription problem to the interpretation problem. The former goal response had a 16 KiB JSON limit and required the complete source inside that JSON, despite native retention allowing 32 KiB. Each copied clause also had a 512-scalar / 2,048-byte limit, and generation had only 1,024 output tokens. Consequently, some byte-admitted inputs could not be represented by that response contract regardless of model competence. Independent input-token admission could reject a request even earlier.

Source ownership and semantic interpretation should be separate. A model can propose boundaries and labels; native code must reconstruct source, establish complete coverage, and retain the original task and question lineage. Complete coverage still does not establish correct interpretation, available website capabilities, authorization or task success.

## Implemented contract

The [goal planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) constructs an immutable source catalogue for the exact completion request. Foundation's nonlocalized word-start enumeration supplies candidate boundaries. Only boundaries at complete Swift characters are retained. Pieces preserve original UTF-8 bytes, including separators, leading nonword text, repeated occurrences, combining marks and emoji. A boundary is an available reference point, not a native semantic classification.

Goal context version 5 represents each original request and clarification answer as ordered `[piece ID, exact text]` pairs. Piece IDs begin at zero independently for each turn. The text replaces the literal source field; it is not appended as another complete copy. Original clocks, fixed native question text and exact question scopes remain. Scope excerpts still contain literal source. Other browser planners keep their existing literal context format and versions. Transport identities and hashes remain host-side.

The closed `browser_goal_proposal_v5` response replaces each row's `source` with an integer `through`: the inclusive final piece of that clause. Its start is the first unused piece of that turn. Native decoding rejects invalid types, out-of-range endpoints, repeated/decreasing endpoints, out-of-order turns, missing turn coverage, extra fields and mixed literal/reference formats. It concatenates the referenced pieces and applies the existing exact-byte coverage check, literal hint admission, disposition rules and question-scope rules. It calculates the same byte offsets and requirement identities that the equivalent literal partition would have produced.

Production counting, completion and decoding share the same catalogue instance. The model is not asked to calculate Unicode byte offsets or echo transport/revision hashes. Reference numbers do not themselves prove that a model response has the right meaning for a request; native request ownership and later semantic/effect checks remain necessary. The direct literal decoder remains available to existing direct callers and fixtures, with its old limits. The production local planner never falls back to it.

A referenced clause can span the retained source without the old copied-clause size limit. Other limits remain: 32 KiB total input, 8 KiB per answer, 16 user turns, 32 requirement rows, eight question-scope rows, bounded literal hints, 16 KiB response JSON and parser limits. The full model request must still count at most 3,008 input tokens within the 4,096 context, 1,024 output and 64 framing allowance. Invalid or oversized responses cannot silently drop source to become admissible.

Native question history already retains sealed requirements and their original input. Restoring an accepted prefix does not reparse a historical literal response, so it does not impose the old copied-clause cap on newly referenced requirements. The existing question display limits and intervention behavior still apply.

## Authored verification, unrun

Six new methods are registered:

- Five [goal-planner methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalPlannerTests.swift) specify exact Unicode and separator retention, hostile marker text as source, canonical requirement identity and repeated occurrence preservation, a retained source larger than the response limit, invalid/duplicate/incomplete references, rejection of production literal fallback, and preservation of question/disposition/literal-hint checks.
- One [clarification method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) specifies reference decoding across six answers while retaining all original clauses, clocks and accepted question prefixes. Missing, reordered and repeated turns must fail.

Existing local-planner question/wire fixtures now return references, and request fixtures inspect the numbered source and closed schema. The mocked exact-token boundary and cancellation fixtures retain their existing behavior. These fixtures do not run real models, prove login behavior or qualify real websites.

Three changed Swift files pass parse-only checks. Active source inventories select 1841 default / 1158 focused methods, with six additions and no removals. The assertions, Foundation segmentation behavior, native wire execution and model contract have not been executed or typechecked.

## Remaining sequence

1. When execution is authorized, build and run the authored deterministic coverage, question/history, cancellation and canonical identity checks. Include all-whitespace separators, Unicode composition, emoji sequences, scripts without spaces and punctuation without surrounding spaces. Do not infer multilingual semantic support from source preservation.
2. Qualify actual model input counts and complete output on bounded original-plus-answer scenarios. Numbered pieces add input overhead, and the 32-row / 1,024-output-token limits still constrain expressibility. No claim that 32 KiB or 15 answers fit the model follows from native retention. Keep an intact request on context-limit intervention.
3. Measure whether lexical boundaries permit the clause distinctions the native compilers need, especially embedded units, URLs, dates and text without spaces. If a distinction needs finer boundaries, change the native catalogue with explicit coverage fixtures; never manufacture or normalize source text. Punctuation attached to a previous piece may limit a proposed partition.
4. Compare model proposals against known interpretations for negation, comparators, source restrictions, independent requirements and explicit corrections. Stable references reduce transcription work but cannot repair incorrect roles, scopes or semantic associations by themselves.
5. If measured correctness still calls for another model, evaluate alternatives against the same bounded contract and native checks. The user's saved-key RTX 3080 desktop authorization remains available for later work; this change does not retry the unresolved SSH connection, download models, distill or prune.

The global navigation-source completion gate remains disabled pending qualification. Durable recovery, broader corrections/provider controls, 8 GB resource behavior and the real travel/concert/movie/login scenarios remain open. Those end-to-end runs require the user's later explicit permission.

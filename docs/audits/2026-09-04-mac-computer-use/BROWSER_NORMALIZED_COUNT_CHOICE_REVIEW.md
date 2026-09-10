# Keep normalized party counts through native select choices

Source checkpoint: 2026-09-09. Parent: `126ccf2`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A count field may be a number input or a native select. The preceding [party-total repair](BROWSER_PARTY_TOTAL_FORM_REVIEW.md) supplied adult, child and total values, but a select used only a generic choice plus one requirement reference. That representation lost the normalized category and could not carry a complete multi-row source group through its choice payload. A completed select therefore did not create the corresponding party component record.

A second distinction is essential: the semantic count is not the native stored selection. A number field may contain `2`; a select retains an opaque native choice ID whose option label says “2 adults.” Comparing that ID with the string `2` would falsely report a changed criterion. Treating all options with the same count as interchangeable would instead discard the chosen native object and its provider context.

## Proposed choice and source binding

The [form proposal](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) adds `field + choice + normalized`. It requires a current editable select, an exact observed option ID on that field, an offered party/ticket normalization and a compatible complete option label. Hidden or disabled choices, foreign-field IDs, provider submission values, missing/extra keys and date normalizations cannot use this alternative.

The [scalar label reader](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) recognizes a complete integer or supported number word with an optional quantity unit. It never extracts a number from a range, bound, age description, price, package or mixed-category phrase. An explicit unit must match the normalization. The range includes the existing maximum derived party total. The existing number-word table is shared without changing the source-goal grammar.

[Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) advertises context version 23 only when an editable select has at least one matching normalized choice. Date terms, date replacements, totals and other existing fields remain present. [Planner schema](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) version 18 adds the alternative when available; other schema paths keep their existing versions. Instructions retain field meaning and optgroup review as separate obligations.

The normalization's entire source list passes through edit-intent comparison, ordinary provenance and interrupted-stage source retention. An extra single `requirement` cannot shrink that list. Native execution remains the existing `selectChoice` operation on the exact choice ID, with the original input, choice metadata, ownership and verification boundaries. This does not introduce a script or another effect route.

## Count and native representation

Party criterion records now keep both the requested count and the native expected value. Number fields use their numeral; count-linked selects use the selected native choice ID. Coverage requires the count to match the current native party requirement and the observed value to match that exact representation. A different choice ID, even with an equal count label, requires fresh native reconciliation. Existing changed-target and duplicate-category checks remain effective.

The criterion identity now includes a version-2 domain and native representation, and the existing continuation digest includes that identity. [Completed-stage accounting](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) creates records only for verified normalized adult/child payloads. Generic choices, ticket counts and people totals create no adult/child record; replacing a category purpose with one of those removes the old record only after the new criterion is verified.

The public party record still contains only its party alias, unit and count. The new native representation is not added to that record or to historical party snapshots. Observed option IDs remain available in their ordinary current field catalogues for choice selection. History continues to withhold current-field verification after navigation.

This is arithmetic and native correspondence, not proof of provider age categories, field meaning, inventory, availability or whole-task completion. Numeric labels and a model's selected normalization cannot establish those semantics by themselves.

## Authored verification, unrun

Five new methods are registered:

- One [scalar method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) covers complete numeric/word labels, optional units, the supported bound and rejection of modifiers, ages, mixed counts, prices and invalid numbers.
- Four [form methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) cover count versus choice-ID coverage, unit and hidden/disabled rejection, absence of category records for totals/tickets, exact decoder/schema/provenance binding, and preservation of the separate native value. Native fixture paths specify all-input, mixed and observation-only passenger choices followed by one query and historical component accounting. A changed option label must invalidate an earlier proposal before input or a published form stage.

Seven changed Swift files pass parse-only checks. One fixture script passes `node --check` without execution. Default/focused source inventories select 1781 / 1098 methods, with five additions and no removals. These are syntax and source-registration results, not typechecking, assertion results or native/model qualification.

## Remaining repair order

1. Qualify provider field/category and optgroup meaning, including ages/infants, conditional options and localized labels. Unsupported complete labels cannot be treated as a verified count by extracting a convenient numeral.
2. Carry equivalent component accounting through supported custom passenger widgets and other control families. This repair uses native single-select capabilities; it does not add custom dropdown or multi-select execution.
3. Qualify option replacement, metadata drift, retained stages, cancellation and account/document transitions under native timing. Earlier criteria and uncertain actions keep their recovery obligations.
4. Continue the [repair checklist](../../../TODO.md). Global navigation-source completion stays restricted. Live travel/concert/movie tests still require explicit permission; model changes, RTX 3080 adaptation and 8 GB resource qualification remain deferred to their authorized stage.

No model/SSH activity, installed-app replacement, push or generated-file cleanup occurred here.

# Preserve result structure in browser observation

Date: 2026-09-07. Parent source: `41c3c29`. Source integration only; runtime qualification remains pending.

## First-principles finding

A research result is a set of related facts. Seeing a date, a price and a link somewhere on the same page does not establish that they describe the same flight, concert or movie. The existing snapshot assigned each text fragment a nearby container ID, but omitted relationships between those containers. Titles, date paragraphs, prices and links in different nested elements therefore lacked the structural context needed for a subsequent result compiler. Links with only an accessible label had no text-node references and no parent relationship at all.

This is one prerequisite for the still-missing semantic whole-goal and result integration. It does not redefine a successful page observation as a successful ticket search. Structural ancestry supplies evidence for interpretation; it cannot itself prove an offer's meaning, availability, fees or compliance with the user's constraints.

## Source changes

1. Browser snapshots now include a bounded container tree. Each record has an observation ID, parent ID and one fixed structural kind. Text and controls retain their immediate group IDs; links now also retain a group ID, including links whose labels have no text-node references. Wrapper labels, classes and data attributes are not collected. Exact destinations remain private to the host-side link record.
2. The isolated browser script follows the existing composed-parent rule, including assigned slots and shadow hosts. It admits a whole ancestor chain before publishing references, with limits of 128 ancestor traversal steps, 32 represented levels, 256 containers and the existing aggregate byte budget. Unsupported depth or capacity sets explicit omission/truncation markers and omits the dependent record. It does not substitute an unrelated ancestor or fabricate a result association.
3. The host validates unique container IDs, one root, parent-before-child ordering, maximum depth, permitted kinds and references from texts, controls and links. Cycles, aliases, forward references and dangling group IDs are invalid. Both new metadata fields must be present together. Legacy snapshots without either field explicitly report missing structure; a supplied partial tree cannot use that marker to excuse dangling references.
4. Snapshot freshness retains the actual container objects and their structural parents beside existing native link/control bindings. Every existing page, link, query and viewport validation compares them after rereading the page. Replacing a result wrapper while preserving its child objects and serialized text is stale evidence, even if ordinal group IDs and visible content look identical. A fresh observation can subsequently bind the new structure.
5. `ComputerUseBrowserPlanningContext` version 3 projects parent records before their dependent text/link/control records. Shared ancestors appear once. Links still follow their referenced text. Whole-record prefix reduction therefore keeps every included parent and text reference available. Controls remain prioritized with their required ancestors; all records share the existing 64-record/8,192-byte context budget.
6. Source, structure and prompt-budget omissions remain explicit, even with zero projected records. All existing planner adapters receive this projection through their existing browser context. The tools offered, input-token cap and action/answer authority are unchanged. Container relationships remain untrusted page context and do not become a completion predicate or permission to click a link.

## Prepared verification

Five new methods cover:

- Two nested concert cards with separate dates and equal prices, links with and without text nodes, and a form control in one card. Parent relationships keep the cards distinguishable; private wrapper attributes, submission names/values and URLs are excluded from planner context.
- Rendered slotted text, shadow-DOM content, excessive nesting, the shared container limit and omission markers without dangling references.
- Replacement of an actual result wrapper while retaining its children, text, links and control metadata: old evidence and navigation preparation are rejected; fresh evidence remains available.
- Malformed/oversized trees, cycles, duplicate roots/IDs, wrong kinds, missing paired metadata and dangling link references, plus explicit legacy structure loss.
- Every prefix of a size-limited model context retains the parents and text references of its included children, with accurate omission markers. The existing all-adapter prompt fixture now carries a real parent relationship and continues to reject page-only facts as independent answer authority.

The [focused source inventory](browser-result-structure-inventory.json) selects **216** methods and the default inventory **738**. Three changed Swift files pass syntax-only parsing. The production browser script and two new fixture scripts pass JavaScript syntax checking. Source inventories and whitespace checks pass. **No typechecking, assertions, builds, model runs, app launches or computer-use activity occurred.**

## Remaining repair path

The normal semantic route still chooses one GUI action at a time, and the connected deterministic browser driver accepts complete explicit steps. Next work must supply an actual whole-goal semantic compiler and dynamic browser stages for ordinary research language. Preserve the original requirements for locations, dates, counts, comparisons, price limits and fees through login, clarification and page changes.

Use this structure with exact source text/link bindings when compiling candidate results. A shared `article` or other wrapper may contain multiple offers, advertisements, alternatives or contradictory text; ancestry alone must not merge those facts. Verify fact meaning and associations, include explicit unknowns, distinguish partial findings from complete results, and qualify selected shareable source URLs. Multi-page accumulation, custom controls/POST/JavaScript flows, typed intermediate questions and lost-session recovery remain open.

Later explicit permission is still required for runtime and real-site tests. Performance optimization follows correctness repairs; no claim about an 8 GB working set or acceptable thermal behavior follows from source bounds. No generated build or test-result bundles were created in this repair.

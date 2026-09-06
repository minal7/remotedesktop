# Complete explicit text-command compilation

Status: source implementation and regression registration only. No build, test execution, inference, app launch or computer-use interaction was performed. Performance optimization and real-site qualification remain deferred.

## Why this changes planning

The native form capability already executes a complete contract with separate step identities, exact before/after values, typed copy dependencies and dispatch receipts. Its deterministic compiler only recognized quoted `set` clauses. Other clear text operations still went through model interpretation, including the known failure where a quoted source field name became literal input instead of copied data.

The compiler now parses an entire request into commands with separate target, payload-origin, mode and ordering information before resolving any field. It does not turn an action-family history marker or a partial command prefix into execution authority. The existing native executor already accepts its literal and field-copy proposals, so these commands enter the production contract/transaction path without another execution loop.

## Supported operation meanings

| Explicit form | Compiled operation |
| --- | --- |
| `Set "Name" to "Alice"` | Replace the field's whole value with supplied bytes. |
| `Replace "Name" with the text "Alice"` | Replace with literal text, even if Alice is another field label. |
| `Type "!" into "Notes"` or `Insert "!" in "Notes"` | Insert at the retained selection; existing text outside it is preserved. |
| `Append "!" to "Notes"` | Append at the end. |
| `Copy the "Origin" field into "Destination"` | Replace Destination with Origin's ordered current value. |
| `Copy the text "Origin" into "Destination"` | Enter the supplied literal Origin, not that field's value. |
| `Append the current value of "Origin" to "Destination"` | Append copied data with an explicit source dependency. |

The same typed current-value payload can be used with set, replace and insertion. Field names remain bound to unique editable, non-secure observed controls. An unnamed or ambiguous reference yields clarification only after the complete syntax has been consumed.

Commands can be sequenced with explicit connectors, commas, semicolons or periods. Existing abbreviated repeated `set` syntax remains supported. Explicit once/twice/count repetitions expand to separate operations, capped at eight total. “The same field” refers to the preceding target; when a copied source is mentioned before that reference and competes with the earlier target, the compiler asks for clarification. A target reference appearing before a new source mention remains bound to the earlier target.

Quoted content is lexed directly from the original request and remains byte-preserving data. It cannot become a connector, action or synthetic payload ID. The compiler permits sixteen quoted target/value arguments for eight operations while retaining the model planner's separate eight-payload catalog limit. Other host input and value-size limits still apply.

## Regression selection

Four new compiler methods specify exact operation vectors, modes, repeated target binding, copied versus literal origins, updated sources, self-copy, Unicode/whitespace preservation, model-marker-looking data, eight-operation bounds, ambiguity, protected fields and rejection of partial/conditional/alternative requests. Missing early targets do not hide an unsupported later instruction.

A new controlled DOM method uses the production capability coordinator, native form executor and browser dispatch adapter. It specifies two equal-value replacements, a copy, two appends to the same target, and a final literal equal to a field name. Its independent page event log checks both edited fields and the preserved field after every event. A second call with the same task must add no events; all six journal steps must remain distinct and verified. The injected model planner and desktop fallback must not be called.

The [82-method focused inventory](complete-text-command-inventory.json) and the 442-method default inventory match source. `git diff --check` passes. These checks do not establish compilation or runtime success; none of the new methods has been run.

## Remaining work

This compiles explicit form-edit sequences. It does not interpret all English, produce generated drafts, infer missing field names, compile conditional or forbidden-value constraints, bind controls that appear later, or submit and verify searches. Unsupported syntax goes to the existing whole-goal planner with the complete request, whose broader semantic qualification remains open. Bare quoted copy operands without a source-field or literal-text role are not guessed by this compiler.

Native AX and owned-browser composition still need qualification under the user's test gate. Visual task-wide TYPE/ENTER suppression remains until visual actions have complete authorized step/target contracts and durable receipts. Travel, concert and movie workflows, host restart recovery, mobile transport and the 8 GB target remain unqualified.

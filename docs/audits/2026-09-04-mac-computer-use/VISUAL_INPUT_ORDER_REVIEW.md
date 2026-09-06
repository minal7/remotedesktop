# Visual input ordering and exact history

Status: source implementation and regression registration only. No build, test execution, model run, app launch or computer-use interaction was performed. Performance optimization and real-site scenarios remain deferred.

## Findings

The visual executor previously authorized typing from any affirmative clause in the task and Return from any later submission clause. A model could therefore skip an earlier click or type a later requested payload into the current field. Editable focus proves that input is possible; it does not prove that this is the next requested operation.

Separately, the ordered pointer resolver consumed typed history with a case-insensitive comparison. `TYPE [alpha]` could satisfy a prior `ALPHA` request. Long entries retained only 1,000 escaped characters, allowing different payloads to share an apparent completion marker. An unqualified TYPE family match also consumed an uncompiled unquoted payload. None of these establishes the exact preceding effect.

## Implemented boundary

- Pointer and input queries now share one ordered parser. The input query supplies only the next clause to the existing payload/Return policy. Earlier application, pointer, input and unsupported-effect clauses remain prerequisites. Signed current application identity can satisfy the existing explicit application scope rule.
- A quoted input must be an unambiguous direct literal object and match the entire payload's UTF-8 bytes. A quoted field label, a substring, a differently normalized string or a later clause cannot supply that authority. The existing literal-reference path resolves its host-owned payload and applies the same clause check.
- Completed typed history compares exact bytes. Long entries retain their existing bounded display plus SHA-256 of the complete, unescaped payload bytes. The parser and executor use the same history encoder. Legacy clipped long entries cannot advance the sequence.
- Bare `TYPE` remains only a unique, compacted router hint when the history is explicitly incomplete. It cannot satisfy the executor's complete host ledger. An unquoted/generated input without a compiled exact payload cannot be consumed merely because its action family matches.
- `Press Return … in the focused field` is recognized as a key operation; a control named Return does not acquire key authority. Target validation, dispatch checks, pending-approval retention and global TYPE/ENTER repeat suppression remain in place.

## Regression changes and evidence

Three new resolver methods cover sequence advancement, unknown barriers, signed application scope, quoted command words, key/control ambiguity, case and Unicode differences, whitespace, escaping and long payload collisions. Two new executor methods exercise the production policy with stub planners and an intercepted input sink: rejected proposals produce no input or visual completion, valid distinct inputs progress through recorded effects, and repeated identical typing/Return remains suppressed.

Six existing methods were revised. Three typing/caret fixtures now explicitly request typing into their already focused field; they no longer claim an omitted activation happened. The comma-separated Return fixture actually types before submitting. The direct-input fixture uses the supported explicit literal clause. Its previous declarative-prefix phrasing is retained among rejected cases so this newly exposed capability gap is visible. The existing pointer-order method now rejects an uncompiled unquoted completion instead of accepting a TYPE family marker.

The [focused inventory](visual-input-order-inventory.json) selects 23 exact source methods. It and the 432-method default inventory match source; `git diff --check` passes. This establishes registration and whitespace checks, not compilation, runtime behavior or natural-language qualification.

## Remaining repairs

This is a conservative ordering guard, not a whole-goal compiler. The current grammar can reject valid declarative scope, multi-quote target/payload instructions and later steps after unquoted/generated typing. Complete task compilation must retain their constraints and assign exact input and target roles rather than silently skipping prose or inferring completion from action-family history.

The visual executor still needs stable authorized step IDs, target/document generations, exact operation identities, attempted/verified/uncertain receipts, durable recovery and predicates for every requested result. Existing pointer history proves neither target identity nor remote application outcome. A digest identifies input bytes; it does not prove a browser submission or a successful search.

Do not remove the global repeat guards until these contracts cover repeated inputs and submissions. Qualify the preserved natural-language travel, concert and movie scenarios only after development readiness and the user's explicit permission.

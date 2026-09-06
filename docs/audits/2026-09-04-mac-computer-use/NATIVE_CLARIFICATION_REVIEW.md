# Native form clarification ownership

Status: source implementation and regression registration only. No build, test execution, inference, app launch or computer-use interaction was performed. Performance optimization and real-site qualification remain deferred.

## Problem and required behavior

A clarification answer only makes sense in the context of the original request and the objects that prompted the question. A field with the same label is not necessarily the same field. Conversely, ordinary value and selection changes while a user answers do not necessarily create a different form.

The native executor previously returned a question for both AX and owned-browser forms, but only the browser path retained a pending clarification. A native answer therefore lacked the executor scope required by the existing host/controller continuation protocol. Its appearance as a question did not establish that it could be resumed.

The executor now retains either an owned-browser form or a native AX form. The public clarification representation and existing controller/session-bound host protocol remain the same. Native answers enter the existing text contract, journal, action gate and AX editor.

## Native scope and observation

The native scope binds the original supported field set by opaque AX reference ID and exact label bytes. Those IDs come from the production AX adapter, whose bindings include application launch, window, document, element, role/subrole, identifier, label object and parent references. A digest alone is not accepted as proof of membership.

Each scope check discovers the current supported field set, requires the exact retained ID set and labels, and re-reads each retained reference to verify its current snapshot. New, missing, replaced, repurposed, protected or relabelled supported fields invalidate the pending request. This includes equal-looking replacement objects and canonically equivalent labels with different UTF-8 bytes. Discovery cannot supply replacement authority for a missing retained object. Restoring the old appearance after a rejected observation does not recreate the executor's consumed clarification.

The digest excludes field values and selections. An answer re-observes those values and selections, in the original field order, before planning. Scope checks are read-only and can run while the action gate is paused; continuation cannot plan or edit until the gate permits it. A focus change between labelled fields in the same intact form does not itself change the scope. The existing “Focused field” fallback for an unlabelled control remains conservative: moving focus can change the discovered set and invalidate its clarification.

## Goal and lifetime ownership

The original request, question and exact answer bytes remain a bounded `ComputerUseUnresolvedTextGoal`. Before any suspension, the executor consumes the old question and binds continuation to one exact answer task ID, originating task ID and full goal. Native scope transfer preserves the same AX references; it does not acquire another application's form. Browser transfer retains its existing document lease behavior.

Planning cancellation retains the prepared answer so that only the same task and goal can resume it. A fresh request cannot reuse that prepared answer ID. Completed native edits reuse the existing retained task and journal behavior, so duplicate answer delivery does not request another proposal or repeat input. Additional questions retain the same form while preserving the growing goal and existing four-turn bound.

The review also found a shared expiry hole: an answer planner returning another question could renew authority after the preceding clarification expired or was invalidated. The executor now validates prepared ownership, scope and expiry before accepting any planner outcome, including clarification and unsupported outcomes. It checks expiry after potentially blocking native scope reads, after fresh-value observation before starting planning, and again before issuing a new question. The existing pre-contract checks also validate native scope. Expiry and explicit invalidation cannot become another pending question or a new edit.

## Source fixtures

Six new methods exercise the real AX adapter, executor, text contract and native setter path through the existing injected AX graph. They specify:

- Exact original/answer text and reference preservation, fresh values and selection, read-only inspection while paused, action gating and one edit across duplicate completion delivery.
- Twelve scope changes: application launch, unavailable application, window, document, label, Unicode label bytes, role, parent, protection, field removal, field addition and equal-looking replacement. Every change must stop before a journal or AX write and remain invalid after restoration.
- Form membership changes during initial-question, answer-question and answer-edit planning.
- Rewritten original requests/questions, cancellation during answer planning, rejection of competing answer IDs/origins/goals and successful retry of the original prepared answer.
- Twelve outcome/invalidation combinations: another question, unsupported proposal and edits, each with expiry during planning, expiry during a subsequent AX scope read, expiry during fresh-value observation or explicit invalidation. Expiry during fresh-value observation must prevent planning from starting.
- Multiple questions with stable scope, duplicate question delivery without another proposal, and the four-turn terminal bound.

One new owned-browser method covers six planner-outcome/expiry-or-invalidation combinations through the same executor. Its page event log must remain empty. These are fixture specifications, not executed results or evidence of local-model interpretation quality.

The [131-method focused inventory](native-clarification-inventory.json) and the 449-method default inventory match source. `git diff --check` passes. No Swift compilation or runtime verification was performed.

## Remaining work and limits

Native scope support remains unqualified until builds and controlled execution are authorized. Qualify actual AX applications, actual model interpretation, controller/host composition with native fields, phone UI, transport and pause/resume. Existing browser execution evidence does not qualify this new native path.

This observes the adapter's bounded supported field set, not every widget or every possible AX lifecycle event. An application/window/document change entirely between observations cannot be proven absent; native lifecycle/generation work remains open. Unsupported controls, shadow/iframe browser workflows, future fields, submissions and whole search-result completion remain separate repairs. AX reads and input are not an atomic transaction across processes, and durable recovery of native input still lacks an independent OS dispatch receipt.

Whole-form checks add AX observation work. Their latency and resource cost require measurement in the later performance phase; no 8 GB or thermal claim follows from this repair. Travel, concert and movie website scenarios remain deferred pending the user's explicit permission.

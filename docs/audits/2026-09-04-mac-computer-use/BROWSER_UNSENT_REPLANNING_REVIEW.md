# Refresh an unsent browser destination after login

Date: 2026-09-07. Parent source: `7d1552b`. Source repair only; runtime qualification remains pending.

## First-principles defect

A prepared page reference is a plan. An attempted network request is an effect whose outcome may be unknown. They need different recovery rules. Preserving a stale plan indefinitely makes recovery impossible; discarding an attempted effect can send a duplicate request.

The explicit browser driver retained a prepared link or native GET-query target before opening it. The navigation facade durably recorded `planned` before DOM validation. If login, control loss or a changed page stopped validation, no native attempt existed, but Resume kept the old target. Fresh page evidence could not repair this: the existing journal correctly rejected a changed payload under the same operation ID. Inventing another ID would bypass replay protection.

## Source repair

1. Add an explicit journal operation for replacing an **entirely unattempted binding**. Both the expected and replacement records must have only `planned` statuses. Exact task bytes, original prompt digest and ordered operation-ID bytes must remain identical; only the binding digest can change. Ordinary `save` retains its immutable identity and monotonic status rules.
2. Rebinding uses the existing cross-instance execution exclusion, exact expected-record comparison, atomic replacement and file/directory synchronization. A failed replacement poisons that store instance. An old caller cannot overwrite a newer binding or advance its stale plan to an attempt.
3. Expose read-only native attempt presence separately from receipt lookup. Missing receipts do not establish that nothing happened. Even an attempt interrupted in the durable callback before native load blocks rebinding conservatively.
4. The navigation facade's explicit refresh method validates the original record, acquires the same operation's execution lease, and checks both durable status and native attempt absence before invoking fresh preparation. The lease covers asynchronous preparation, fresh target validation and replacement. It captures browser session/ownership identity and rechecks it, cancellation and native attempt absence after awaits. A foreign target or invalid/currently unpresented document cannot replace the record.
5. A never-recorded, never-attempted target may receive an initial fresh `planned` binding. A recorded unsent target may receive an atomic replacement. Attempted, uncertain or verified records return the retained target without invoking preparation; normal execution then reconciles only the existing receipt. The original observed-navigation API still rejects implicit payload changes.
6. The driver invokes refresh only for a destination retained from a previous run. Fresh preparation repeats the original stage's unique label resolution in the current owned page, under the full original prompt and stable stage ID. It publishes the new cached target only after durable replacement succeeds. Missing or ambiguous labels keep the task pending; authentication still propagates to manual login and explicit handback.
7. Query preparation continues to consume the preceding retained form executor's verified continuation. Fresh observation cannot substitute current field values for the original final values, discard unchanged-field requirements, recreate lost input receipts or repeat completed edits. A full document replacement that loses this authority remains blocked.
8. The parent workflow's contract and operation IDs do not change. The parent `attempted` state denotes delegated work, while the child record establishes whether navigation was attempted. This distinction allows an unsent child to refresh without rewinding the parent or a real effect.

## Prepared verification

Nine new XCTest methods cover:

- Explicit planned replacement, exact task/prompt/step identity (including Unicode byte distinctions), rejection of every advanced status, stale writers, execution exclusion and failure after rename.
- Links and native queries refreshed from changed DOM evidence, with both absent and existing planned records, exactly one eventual destination request, unchanged whole-goal/operation identity and rejection of the old cached payload.
- Durable attempted/uncertain/verified states without receipts and a native-only attempt with a planned record: none permits preparation or replay.
- A competing opener or refresher while asynchronous preparation holds the lease; changed original goal; failed durable replacement that cannot publish a new target.
- Missing, foreign, stale or unowned fresh evidence leaves the prior planned record intact.
- An explicit workflow paused at destination validation, an inline login challenge, explicit handback, login completion, and another Resume. Link recovery includes same-session history/location changes; query recovery keeps the original Paris edit, sends once and never re-edits. A manual change to Tokyo remains blocked. All cases retain parent and child stage identities.

The [focused source inventory](browser-unsent-replanning-inventory.json) selects **211** methods; the default inventory selects **733**. These counts describe reviewed source selection, not executed or passing tests. Seven changed Swift files pass syntax-only parsing. Embedded fixture JavaScript syntax, source inventories and whitespace are checked separately. **No typechecking, assertions, builds, models, app launches or computer-use activity were run.**

## Remaining work

This repairs recovery in the explicit browser driver. It does not complete general natural-language research or qualify live login providers. Continue the semantic whole-goal compiler and complete result predicates for travel, concerts and movies; preserve dates, locations, counts, budgets and fee/availability requirements through dynamic stages and report source-associated facts. Add site-required custom controls, JavaScript/POST behavior and typed intermediate clarifications as separate reviewed capabilities. Durable recovery after browser/host loss, account proof and provider compatibility remain open.

After later explicit permission, typecheck and run controlled gates before bounded real-site scenarios. Keep model holdouts unused. Performance optimization and measured 8 GB/thermal qualification follow correctness repairs. No build/result bundles were created here; about 16 GiB remained free, so no obsolete generated cleanup was needed.

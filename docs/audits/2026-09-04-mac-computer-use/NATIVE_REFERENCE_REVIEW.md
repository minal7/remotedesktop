# Native reference retirement and semantic scope

Date: 2026-09-06. Parent source: `1ffdb30`. Status: implemented in source; compilation and execution remain paused. This checkpoint advances F04/F06/F09/F13/F26. It does not close native generation tracking.

## First-principles findings

The authority to edit a field comes from the observed control and its meaning in the task. Equal current text and the same AX object are insufficient if the application repurposed that object.

The adapter previously retained an ID based on application launch, AX element, window and exposed document identity. It did not include the planning label, role/subrole, control identifier, label reference or complete parent chain. A field could therefore acquire a different meaning in the same document without changing the ID a planned step would use.

An observed invalid state also left the old binding in the array. For example, a read could observe a protected or detached field and return nil; after it returned to its previous state, the old ID could become valid again. Once a reference has failed validation, that failure cannot be erased by later matching bytes.

Finally, native discovery read the planning label separately after creating the snapshot. A label change between those reads could pair one snapshot's authority with a different observed name.

## Repair

- A binding now includes exact role, subrole, AX identifier, the chosen label text, the associated label object and the ordered AX ancestor references through the current window. Metadata strings use byte equality. Ordinary value/selection changes remain separately verified edit state and do not create a different identity.
- A changed binding shape retires the old ID and issues a new one. Restoring the former metadata cannot revive the old authority after the change was observed.
- Any failed observation of that exact control removes its retained bindings. Missing/unsupported role, protection, disabled state, unreadable/oversized value, invalid selection, detached membership, a cyclic parent chain or unsupported metadata therefore cannot leave a reusable old reference behind. A fresh explicit observation may create new authority if the control becomes valid again.
- Discovery uses the label captured by the snapshot's binding. It no longer performs another label read to construct the model-facing field list.
- An `AXTitleUIElement` value is used as a label only when it exposes unprotected static text. The adapter does not treat a protected or editable field's value as planning-label content. Existing explicit title/description/placeholder labels and the focused-field fallback remain available. Binding labels are bounded to 256 UTF-8 bytes and identifiers to 1,024 bytes.
- The AX access boundary is injectable: current application/root, attribute reads, settable checks, writes and message timeouts. Production forwards to the same system APIs. Tests can exercise the production binding/retirement code and native executor with local CF handles and an attribute graph, without launching or contacting an application.

The existing explicit expected-target setters still reject stale IDs before writes. No new model prompt, planner candidate, resource setting, permission or installed app changed. Journals continue to contain IDs/statuses rather than field contents.

## Prepared regression evidence

Six methods in the new `ComputerUseAccessibilityTextTargetTests` class cover the actual production adapter through the injected AX boundary:

| Method | Required observation |
|---|---|
| `testNativeReferenceRejectsSemanticOrParentChangesWithIdenticalValues` | Changed label, byte-distinct Unicode label, identical-text replacement label object, role, subrole, identifier or parent retires authority even though the value is unchanged. Every old focus/selection/setter call rejects; restoring metadata cannot revive the first ID. |
| `testObservedInvalidNativeFieldsCannotReviveOldAuthority` | Missing role, disabled/protected/secure field, invalid selection, cycle or detachment rejects. Protection rejects before a value read. After restoring the field, old IDs still reject, while a newly observed ID can edit it. |
| `testNativeTypingAndOtherFieldReadsPreserveTheExplicitTarget` | Selection and selected/whole-value input stay on the intended native/AX-web field after reading another control. Ordinary editing retains its ID. A focus change during settable lookup prevents a write. |
| `testNativePlanningUsesTheLabelBoundByItsSnapshot` | A label changes immediately after its first read. Discovery returns the originally bound label and the next validation rejects that old ID; no setter runs. |
| `testNativePlanningLabelsDoNotReadProtectedOrEditableTitleValues` | Valid static labels are available; protected, editable and secure title objects never have their values read for the planning label. |
| `testNativeTaskRejectsRepurposedPlanningTargetAndAcceptsFreshAuthority` | The production native executor rejects a field relabeled during fixture planning before journal creation or any AX write. A separate fresh task may use the new observed control, verify exact input and replay without extra input. |

The Xcode test target explicitly includes the new source file, and `project.yml` already includes its directory. The SwiftPM test target also discovers the file through its source directory.

Completed lightweight checks:

- `git diff --check` passes.
- `plutil -lint` accepts the updated Xcode project.
- Default inventory matches **427 exact source methods**.
- The [focused inventory](native-reference-inventory.json) matches **107 exact source methods** across AX reference, editor, text-task, browser DOM and transaction-engine tests.
- Source inspection confirms that production AX reads, capability queries, writes and timeouts go through the injected boundary; the fixture substitutes all four and records reads/writes independently of adapter return values.

These are source/project checks only. None of the new methods has compiled or executed. No build, test run, inference, app launch, computer-use action or website scenario ran. Previously signed test evidence does not qualify this patch.

## Remaining work

1. **Changes entirely between reads remain unobserved.** Destroying/reusing an object or changing/restoring its role before the next snapshot still needs native lifecycle/generation evidence. This patch retires observed changes; it is not an AX observer implementation.
2. **Notification support and lifetime need qualification.** The installed Apple SDK documents `notificationUnsupported` for `AXObserverAddNotification`, and warns that a destroyed element may be compared locally but must no longer be queried through AX. An observer design must preserve those rules, avoid callbacks into released state, distinguish task-caused value changes from structural changes and keep unsupported coverage explicit. See [Apple's observer run-loop lifecycle](https://developer.apple.com/documentation/applicationservices/1459139-axobservergetrunloopsource) and the installed SDK's `AXUIElement.h` / `AXNotificationConstants.h`.
3. **Cross-process mutation is not atomic.** A control can change after validation or in a setter callback. Exact readback, conservative uncertainty and non-replay remain necessary. Unicode destination content/caret is still verified per chunk.
4. **App-specific behavior is unqualified.** Dynamic labels, AppKit/WebKit role conventions, metadata limits and transient AX failures need real native fixtures once execution is allowed. Retiring an observed-invalid ID deliberately requires fresh authority rather than assuming a transient error erased no relevant changes.
5. **Broader product repairs remain.** Whole-goal planning, visual per-step TYPE/ENTER authority, browser submissions/results, model holdouts, mobile transport and real travel/concert/movie scenarios remain open. Real-site tests still require explicit future permission. Metadata/observation cost and the 8 GB target remain for the deferred performance phase.

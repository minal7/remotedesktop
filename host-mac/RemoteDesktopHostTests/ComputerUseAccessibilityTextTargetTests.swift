import ApplicationServices
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseAccessibilityTextTargetTests: XCTestCase {
    func testNativeReferenceRejectsSemanticOrParentChangesWithIdenticalValues() throws {
        for change in ["label", "unicode-label", "label-object", "role", "subrole", "identifier", "parent"] {
            let graph = AXTextGraph()
            if change == "label-object" { graph.set("destination", kAXTitleAttribute, nil) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            switch change {
            case "label": graph.set("destination", kAXTitleAttribute, "Different purpose" as NSString)
            case "unicode-label": graph.set("destination", kAXTitleAttribute, "cafe\u{301}" as NSString)
            case "label-object": graph.set("destination", kAXTitleUIElementAttribute, graph.element("other-label"))
            case "role": graph.set("destination", kAXRoleAttribute, kAXComboBoxRole as NSString)
            case "subrole": graph.set("destination", kAXSubroleAttribute, "AXSearchField" as NSString)
            case "identifier": graph.set("destination", "AXIdentifier", "new-purpose" as NSString)
            default: graph.moveDestination(to: "other-group")
            }
            XCTAssertNil(target.snapshot(targetID: before.targetID), change)
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let changed = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(changed.targetID, before.targetID); XCTAssertEqual(changed.value, before.value)
            graph.restoreDestination()
            if change == "label-object" { graph.set("destination", kAXTitleAttribute, nil) }
            let restored = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(restored.targetID, before.targetID, "Returning to the original metadata must not revive old authority")
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testObservedInvalidNativeFieldsCannotReviveOldAuthority() throws {
        for change in ["missing-role", "disabled", "protected", "secure", "invalid-selection", "cycle", "detached"] {
            let graph = AXTextGraph()
            // Construct the production adapter against this graph; no AX IPC
            // occurs through the fixture access boundary.
            let observed = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(observed.snapshot())
            let valueReads = graph.readCount("destination", kAXValueAttribute)
            switch change {
            case "missing-role": graph.set("destination", kAXRoleAttribute, nil)
            case "disabled": graph.set("destination", kAXEnabledAttribute, kCFBooleanFalse)
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "secure": graph.set("destination", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "invalid-selection": graph.setSelection("destination", NSRange(location: 100, length: 0))
            case "cycle": graph.set("destination", kAXParentAttribute, graph.element("destination"))
            default: graph.set("destination", kAXParentAttribute, nil)
            }
            XCTAssertNil(observed.snapshot(targetID: before.targetID), change)
            if ["missing-role", "disabled", "protected", "secure"].contains(change) {
                XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), valueReads, "Invalid/protected controls must be rejected before reading their value")
            }
            graph.restoreDestination()
            XCTAssertNil(observed.snapshot(targetID: before.targetID), "Restored visible state cannot revive an observed-invalid reference")
            assertRejected(observed, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let fresh = try XCTUnwrap(observed.snapshot())
            XCTAssertNotEqual(fresh.targetID, before.targetID)
            XCTAssertEqual(try observed.replaceSelectedText("!", expected: fresh), true)
            XCTAssertEqual(graph.value("destination"), "old!")
        }
    }

    func testNativeTypingAndOtherFieldReadsPreserveTheExplicitTarget() throws {
        for web in [false, true] {
            let graph = AXTextGraph()
            if web { graph.set("group", kAXRoleAttribute, "AXWebArea" as NSString) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let fields = target.fields()
            let before = try XCTUnwrap(fields.first { $0.label == "café" }).snapshot
            let source = try XCTUnwrap(fields.first { $0.label == "Source" }).snapshot
            _ = target.snapshot(targetID: source.targetID)
            XCTAssertTrue(try target.select(NSRange(location: 0, length: 3), expected: before))
            let selected = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(selected.targetID, before.targetID)
            _ = target.snapshot(targetID: source.targetID)
            let applied: Bool?
            if web { applied = try target.replaceWebValue("Paris", expected: selected) }
            else { applied = try target.replaceSelectedText("Paris", expected: selected) }
            XCTAssertEqual(applied, true)
            let after = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(after.targetID, before.targetID); XCTAssertEqual(after.value, "Paris")
            XCTAssertEqual(graph.value("source"), "source text")
            XCTAssertTrue(graph.writes.allSatisfy { $0.element == "destination" })
            let previousWrites = graph.writes.count
            graph.onCapabilityQuery = { [weak graph] in graph?.focused = "source" }
            XCTAssertThrowsError(try target.replaceSelectedText("wrong", expected: after)) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
            }
            graph.onCapabilityQuery = nil
            XCTAssertEqual(graph.writes.count, previousWrites, "A focus change during capability lookup cannot reach its setter")
            graph.focused = "destination"
            XCTAssertEqual(target.snapshot()?.targetID, before.targetID, "Reading/focusing another intact field is not a structural replacement")
        }
    }

    func testNativePlanningUsesTheLabelBoundByItsSnapshot() throws {
        let graph = AXTextGraph()
        var changed = false
        graph.afterRead = { [weak graph] element, attribute in
            if element == "destination", attribute == kAXTitleAttribute, !changed {
                changed = true
                graph?.set("destination", kAXTitleAttribute, "Changed after observation" as NSString)
            }
        }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let fields = target.fields()
        let field = try XCTUnwrap(fields.first { $0.snapshot.value == "old" })
        XCTAssertTrue(changed); XCTAssertEqual(field.label, "café")
        XCTAssertNil(target.snapshot(targetID: field.snapshot.targetID))
        assertRejected(target, expected: field.snapshot)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativePlanningLabelsDoNotReadProtectedOrEditableTitleValues() throws {
        for kind in ["static", "protected", "editable", "secure"] {
            let graph = AXTextGraph()
            graph.set("destination", kAXTitleAttribute, nil)
            if kind != "static" { graph.set("label", kAXValueAttribute, "private title contents" as NSString) }
            if kind == "protected" { graph.set("label", "AXProtectedContent", kCFBooleanTrue) }
            if kind == "editable" || kind == "secure" { graph.set("label", kAXRoleAttribute, kAXTextFieldRole as NSString) }
            if kind == "secure" { graph.set("label", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString) }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let field = try XCTUnwrap(target.fields().first { $0.snapshot.value == "old" })
            XCTAssertEqual(field.label, kind == "static" ? "café" : "Focused field")
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), kind == "static" ? 1 : 0)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeTaskRejectsRepurposedPlanningTargetAndAcceptsFreshAuthority() async throws {
        let graph = AXTextGraph(), planner = AXGraphPlanner()
        planner.beforeProposal = { [weak graph] in graph?.set("destination", kAXTitleAttribute, "Repurposed field" as NSString) }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("AX fixture must not emit keys") }),
            mayAct: { true }, journalDirectory: directory, planner: planner, nativeTarget: target)
        do { _ = try await executor.execute(taskID: "original", prompt: "Apply the requested form edit", progress: { _ in }); XCTFail("The old label cannot authorize a repurposed field") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        XCTAssertTrue(graph.writes.isEmpty); XCTAssertEqual(graph.value("destination"), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        planner.beforeProposal = nil
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "fresh-request", prompt: "Apply the newly observed form edit", progress: { _ in })
            guard case .completed = result else { return XCTFail("A fresh reviewed target must remain usable") }
        }
        XCTAssertEqual(graph.value("destination"), "Paris"); XCTAssertEqual(graph.value("source"), "source text")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.map(\.element), ["destination"])
        XCTAssertEqual(planner.calls, 2)
    }

    func testNativeClarificationPreservesExactGoalAndReferencesWithFreshValuesAndNoReplay() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, mayAct: { allowed })
        let prompt = "Put \"  blue\ncafe\u{301} 🧭  \" in the correct field."
        guard case .clarificationRequired = try await executor.execute(taskID: "question", prompt: prompt, progress: { _ in }) else {
            return XCTFail("An unresolved native form needs a retained question")
        }
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "  Use the café field.  ")
        XCTAssertTrue(pending.goal.userTurns[0].utf8.elementsEqual(prompt.utf8))
        XCTAssertTrue(graph.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        graph.set("source", kAXValueAttribute, "fresh source" as NSString)
        graph.set("destination", kAXValueAttribute, "fresh destination" as NSString)
        graph.setSelection("destination", NSRange(location: 2, length: 0))
        graph.focused = "source"
        allowed = false
        XCTAssertEqual(try executor.clarification(taskID: "question"), pending, "Read-only scope checks remain available while paused")
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Paused input is forbidden") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
        XCTAssertTrue(graph.writes.isEmpty)
        allowed = true
        for _ in 0..<2 {
            guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
                return XCTFail("The exact native answer should complete and replay without another edit")
            }
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer])
        XCTAssertEqual(planner.observations[0].map { $0.snapshot.targetID }, planner.observations[1].map { $0.snapshot.targetID })
        XCTAssertEqual(planner.observations[1].first { $0.label == "Source" }?.snapshot.value, "fresh source")
        XCTAssertEqual(planner.observations[1].first { $0.label == "café" }?.snapshot.selection, NSRange(location: 2, length: 0))
        XCTAssertTrue(try XCTUnwrap(graph.value("destination")).utf8.elementsEqual("  blue\ncafe\u{301} 🧭  ".utf8))
        XCTAssertEqual(graph.value("source"), "fresh source")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.map(\.element), ["destination"])
        XCTAssertNil(try executor.clarification(taskID: "question"))
        XCTAssertNil(try executor.clarification(taskID: "answer"))
    }

    func testNativeClarificationRejectsChangedScopeAndCannotReviveItAfterRestoration() async throws {
        for change in ["application", "missing-application", "window", "document", "label", "unicode-label",
                       "role", "parent", "protected", "removed", "added", "replacement"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
            _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
            let answer = try pending.goal.answering(pending.question, with: "café")
            switch change {
            case "application": graph.applicationIdentity = "different-process-launch"
            case "missing-application": graph.applicationAvailable = false
            case "window": graph.set("application", kAXFocusedWindowAttribute, graph.element("other-window"))
            case "document": graph.set("window", kAXDocumentAttribute, "different-document" as NSString)
            case "label": graph.set("destination", kAXTitleAttribute, "Different purpose" as NSString)
            case "unicode-label": graph.set("destination", kAXTitleAttribute, "cafe\u{301}" as NSString)
            case "role": graph.set("destination", kAXRoleAttribute, kAXComboBoxRole as NSString)
            case "parent": graph.moveDestination(to: "other-group")
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "removed": graph.set("group", kAXChildrenAttribute, [graph.element("source")] as CFArray)
            case "added": graph.addField("replacement", label: "café")
            default:
                graph.addField("replacement", label: "café")
                graph.set("group", kAXChildrenAttribute, [graph.element("replacement"), graph.element("source")] as CFArray)
            }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Changed scope must reject: \(change)") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification, change) }
            graph.applicationIdentity = "fixture-process-launch"; graph.applicationAvailable = true
            graph.set("application", kAXFocusedWindowAttribute, graph.element("window"))
            graph.set("window", kAXDocumentAttribute, nil); graph.restoreDestination()
            XCTAssertNil(try executor.clarification(taskID: "question"), change)
            do { _ = try await executor.continueClarification(taskID: "later-answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Restored appearance cannot restore a consumed clarification") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
            XCTAssertEqual(planner.goals.count, 1); XCTAssertTrue(graph.writes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeClarificationRejectsFormDriftWhilePlanningQuestionsOrEdits() async throws {
        for stage in ["initial-question", "answer-question", "answer-edit"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
            planner.beforeProposal = { goal, _ in
                if (goal.userTurns.count == 1) == (stage == "initial-question") {
                    graph.addField("replacement", label: "café")
                    if stage != "answer-edit" { return .clarification }
                }
                return nil
            }
            do {
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question",
                    goal: pending.goal.answering(pending.question, with: "café"), progress: { _ in })
                XCTFail("A field added during planning cannot change the meaning of a retained question")
            } catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification, stage) }
            XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertNil(try executor.clarification(taskID: "answer"))
            XCTAssertEqual(planner.goals.count, stage == "initial-question" ? 1 : 2)
            XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeClarificationBindsCancelledPlanningToOneExactAnswerTask() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "café")
        let rewritten = try ComputerUseUnresolvedTextGoal(userRequest: "Put \"red\" in the correct field.").answering(pending.question, with: "café")
        for goal in [rewritten, try pending.goal.answering("Forged question", with: "café")] {
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: goal, progress: { _ in }); XCTFail("The answer cannot rewrite the unresolved goal") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        }
        planner.beforeProposal = { goal, _ in
            if goal.userTurns.count > 1 { throw CancellationError() }
            return nil
        }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Injected planning cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertTrue(graph.writes.isEmpty)
        for (task, origin, goal) in [("other-answer", "question", answer), ("answer", "other-origin", answer), ("answer", "question", rewritten)] {
            do { _ = try await executor.continueClarification(taskID: task, originatingTaskID: origin, goal: goal, progress: { _ in }); XCTFail("Only the claimed answer may resume") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        }
        do { _ = try await executor.execute(taskID: "answer", prompt: "Start another edit", progress: { _ in }); XCTFail("A fresh request cannot reuse a prepared answer ID") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        planner.beforeProposal = nil
        guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
            return XCTFail("The original answer must remain resumable")
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer, answer])
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationExpiryAndInvalidationDuringPlanningCannotIssueNewAuthority() async throws {
        for invalidation in ["expiry", "scope-expiry", "observation-expiry", "explicit"] {
            for outcome in ["question", "unsupported", "edits"] {
                let graph = AXTextGraph(), planner = AXClarificationPlanner()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                var currentTime = Date(timeIntervalSince1970: 1_000)
                let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, now: { currentTime })
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                let answer = try pending.goal.answering(pending.question, with: "café")
                if invalidation == "observation-expiry" {
                    var discoveries = 0
                    graph.afterRead = { element, attribute in
                        guard element == "window", attribute == kAXChildrenAttribute else { return }
                        discoveries += 1
                        // Pending scope, prepared scope, then fresh values.
                        if discoveries == 3 { currentTime = pending.expiresAt }
                    }
                }
                planner.beforeProposal = { goal, _ in
                    guard goal.userTurns.count > 1 else { return nil }
                    if invalidation == "expiry" { currentTime = pending.expiresAt }
                    else if invalidation == "scope-expiry" {
                        graph.afterRead = { _, _ in currentTime = pending.expiresAt }
                    } else { executor.invalidateClarification(taskID: "answer") }
                    switch outcome {
                    case "question": return .clarification
                    case "unsupported": return .unsupported
                    default: return nil
                    }
                }
                do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Invalidation applies to every planner outcome") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
                // Release the fixture callback's executor capture.
                planner.beforeProposal = nil
                XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertNil(try executor.clarification(taskID: "answer"))
                XCTAssertEqual(planner.goals.count, invalidation == "observation-expiry" ? 1 : 2)
                XCTAssertTrue(graph.writes.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
        }
    }

    func testNativeClarificationRetainsScopeAcrossQuestionsAndStopsAtTheTurnLimit() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner()
        planner.beforeProposal = { _, _ in .clarification }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        var pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let originalScope = pending.scope
        for index in 1..<ComputerUseUnresolvedTextGoal.maximumUserTurns {
            let taskID = "answer-\(index)"
            let goal = try pending.goal.answering(pending.question, with: "  More detail \(index)  ")
            let result = try await executor.continueClarification(taskID: taskID, originatingTaskID: pending.taskID, goal: goal, progress: { _ in })
            XCTAssertNil(try executor.clarification(taskID: pending.taskID))
            if index == ComputerUseUnresolvedTextGoal.maximumUserTurns - 1 {
                guard case .unableToComplete = result else { return XCTFail("The bounded goal must stop asking questions") }
                XCTAssertNil(try executor.clarification(taskID: taskID))
            } else {
                guard case .clarificationRequired = result else { return XCTFail("A supported follow-up must retain its form") }
                let calls = planner.goals.count
                _ = try await executor.continueClarification(taskID: taskID, originatingTaskID: pending.taskID, goal: goal, progress: { _ in })
                XCTAssertEqual(planner.goals.count, calls, "Duplicate delivery of a question must not run planning again")
                pending = try XCTUnwrap(executor.clarification(taskID: taskID))
                XCTAssertEqual(pending.goal, goal); XCTAssertEqual(pending.scope, originalScope)
            }
        }
        XCTAssertEqual(planner.goals.count, ComputerUseUnresolvedTextGoal.maximumUserTurns)
        XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func clarificationExecutor(graph: AXTextGraph, planner: AXClarificationPlanner, directory: URL,
                                       mayAct: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("The AX fixture must not emit keys") }),
            mayAct: mayAct, journalDirectory: directory, planner: planner, now: now,
            nativeTarget: ComputerUseAccessibilityTextTarget(access: graph.access))
    }

    private func assertRejected(_ target: ComputerUseAccessibilityTextTarget, expected: ComputerUseTextSnapshot,
                                file: StaticString = #filePath, line: UInt = #line) {
        let operations: [() throws -> Void] = [{ _ = try target.focus(expected: expected) },
            { _ = try target.select(NSRange(location: 0, length: 0), expected: expected) },
            { _ = try target.replaceSelectedText("wrong", expected: expected) },
            { _ = try target.replaceWebValue("wrong", expected: expected) }]
        for operation in operations {
            XCTAssertThrowsError(try operation(), file: file, line: line) {
                XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged, file: file, line: line)
            }
        }
    }
}

@MainActor
private final class AXClarificationPlanner: ComputerUseTextGoalPlanning {
    var goals: [ComputerUseUnresolvedTextGoal] = []
    var observations: [[ComputerUseTextField]] = []
    var beforeProposal: ((ComputerUseUnresolvedTextGoal, [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal?)?

    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        try await propose(goal: ComputerUseUnresolvedTextGoal(userRequest: prompt), fields: fields)
    }

    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        goals.append(goal); observations.append(fields)
        if let proposal = try await beforeProposal?(goal, fields) { return proposal }
        guard goal.userTurns.count > 1 else { return .clarification }
        let destination = try XCTUnwrap(fields.first { $0.label == "café" })
        let payload = try XCTUnwrap(ComputerUseTextPayloadCatalog(goal: goal).payloads["p1"])
        return .edits([.init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: payload)],
            unchangedTargetIDs: fields.filter { $0.snapshot.targetID != destination.snapshot.targetID }.map { $0.snapshot.targetID })
    }
}

@MainActor
private final class AXGraphPlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    var beforeProposal: (() -> Void)?
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let destination = try XCTUnwrap(fields.first { $0.label != "Source" })
        let source = try XCTUnwrap(fields.first { $0.label == "Source" })
        beforeProposal?()
        return .edits([.init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: "Paris")], unchangedTargetIDs: [source.snapshot.targetID])
    }
}

@MainActor
private final class AXTextGraph {
    struct Write { let element: String; let attribute: String }
    private let names = ["application", "window", "other-window", "group", "other-group", "destination", "source", "label", "other-label", "replacement"]
    private var elements: [String: AXUIElement] = [:]
    private var attributes: [String: [String: CFTypeRef]] = [:]
    private var reads: [(String, String)] = []
    var writes: [Write] = []
    var focused = "destination"
    var applicationIdentity = "fixture-process-launch"
    var applicationAvailable = true
    var afterRead: ((String, String) -> Void)?
    var onCapabilityQuery: (() -> Void)?

    init() {
        // These are local opaque CF handles only. Every operation which could
        // perform AX IPC is supplied by Access below, including timeouts.
        for (index, name) in names.enumerated() { elements[name] = AXUIElementCreateApplication(pid_t(50_000 + index)) }
        set("application", kAXFocusedWindowAttribute, element("window"))
        set("window", kAXRoleAttribute, kAXWindowRole as NSString)
        set("window", kAXTitleAttribute, "Fixture" as NSString)
        set("window", kAXChildrenAttribute, [element("group"), element("other-group")] as CFArray)
        for group in ["group", "other-group"] {
            set(group, kAXRoleAttribute, kAXGroupRole as NSString); set(group, kAXParentAttribute, element("window"))
        }
        for label in ["label", "other-label"] {
            set(label, kAXRoleAttribute, kAXStaticTextRole as NSString); set(label, kAXValueAttribute, "café" as NSString)
        }
        set("source", kAXRoleAttribute, kAXTextFieldRole as NSString)
        set("source", kAXTitleAttribute, "Source" as NSString)
        set("source", kAXValueAttribute, "source text" as NSString)
        set("source", kAXParentAttribute, element("group")); setSelection("source", NSRange(location: 11, length: 0))
        restoreDestination()
    }

    var access: ComputerUseAccessibilityTextTarget.Access {
        .init(frontmost: { [self] in applicationAvailable ? .init(identity: applicationIdentity, root: element("application")) : nil },
              read: { [self] attribute, element in
                  guard let name = name(element) else { return nil }
                  reads.append((name, attribute))
                  let value: CFTypeRef? = name == "application" && attribute == kAXFocusedUIElementAttribute ? self.element(focused) : attributes[name]?[attribute]
                  afterRead?(name, attribute)
                  return value
              }, canSet: { [self] attribute, element in
                  onCapabilityQuery?()
                  return ["destination", "source"].contains(name(element) ?? "")
                      && [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXValueAttribute].contains(attribute)
              }, write: { [self] attribute, value, element in
                  guard let name = name(element) else { return .invalidUIElement }
                  writes.append(.init(element: name, attribute: attribute))
                  if attribute == kAXFocusedAttribute { focused = name }
                  else if attribute == kAXSelectedTextRangeAttribute { set(name, attribute, value) }
                  else if attribute == kAXSelectedTextAttribute {
                      guard let old = self.value(name), let rangeValue = attributes[name]?[kAXSelectedTextRangeAttribute],
                            let text = value as? String else { return .failure }
                      var range = CFRange()
                      guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
                            let swiftRange = Range(NSRange(location: range.location, length: range.length), in: old) else { return .failure }
                      let updated = old.replacingCharacters(in: swiftRange, with: text)
                      set(name, kAXValueAttribute, updated as NSString); setSelection(name, NSRange(location: range.location + text.utf16.count, length: 0))
                  } else if attribute == kAXValueAttribute {
                      set(name, attribute, value)
                      setSelection(name, NSRange(location: (value as? String ?? "").utf16.count, length: 0))
                  } else { return .attributeUnsupported }
                  return .success
              }, timeout: { _, _ in })
    }
    func element(_ name: String) -> AXUIElement { elements[name]! }
    func set(_ name: String, _ attribute: String, _ value: CFTypeRef?) { attributes[name, default: [:]][attribute] = value }
    func value(_ name: String) -> String? { attributes[name]?[kAXValueAttribute] as? String }
    func setSelection(_ name: String, _ selection: NSRange) {
        var range = CFRange(location: selection.location, length: selection.length)
        set(name, kAXSelectedTextRangeAttribute, AXValueCreate(.cfRange, &range))
    }
    func readCount(_ name: String, _ attribute: String) -> Int { reads.filter { $0.0 == name && $0.1 == attribute }.count }
    func addField(_ name: String, label: String) {
        set(name, kAXRoleAttribute, kAXTextFieldRole as NSString); set(name, kAXTitleAttribute, label as NSString)
        set(name, kAXValueAttribute, "old" as NSString); set(name, "AXEditable", kCFBooleanTrue)
        set(name, kAXParentAttribute, element("group")); setSelection(name, NSRange(location: 3, length: 0))
        set("group", kAXChildrenAttribute, [element("destination"), element("source"), element(name)] as CFArray)
    }
    func moveDestination(to group: String) {
        set("destination", kAXParentAttribute, element(group))
        set("group", kAXChildrenAttribute, (group == "group" ? [element("destination"), element("source")] : [element("source")]) as CFArray)
        set("other-group", kAXChildrenAttribute, (group == "other-group" ? [element("destination")] : []) as CFArray)
    }
    func restoreDestination() {
        attributes["destination"] = [kAXRoleAttribute: kAXTextFieldRole as NSString, kAXTitleAttribute: "café" as NSString,
            kAXValueAttribute: "old" as NSString, "AXIdentifier": "destination" as NSString, kAXTitleUIElementAttribute: element("label")]
        moveDestination(to: "group"); setSelection("destination", NSRange(location: 3, length: 0))
    }
    private func name(_ element: AXUIElement) -> String? { names.first { CFEqual(elements[$0]!, element) } }
}

import ApplicationServices
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseAccessibilityTextTargetTests: XCTestCase {
    func testNativeWindowContextPreservesObservedRolesAndUnknownModality() throws {
        for (role, subrole, modal) in [("AXWindow", "AXStandardWindow", false), ("AXWindow", "AXDialog", true),
                                       ("AXSheet", "", nil), ("", "", nil)] as [(String, String, Bool?)] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            graph.set("window", kAXRoleAttribute, role.isEmpty ? nil : role as NSString)
            graph.set("window", kAXSubroleAttribute, subrole.isEmpty ? nil : subrole as NSString)
            graph.set("window", kAXModalAttribute, modal.map { $0 ? kCFBooleanTrue : kCFBooleanFalse })
            graph.set("window", kAXTitleAttribute, "Untrusted \"title\" — cafe\u{301}" as NSString)
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }))
            let window = try XCTUnwrap(catalog.jsonObject["window"] as? [String: Any])
            if role.isEmpty { XCTAssertTrue(window["role"] is NSNull) } else { XCTAssertEqual(window["role"] as? String, role) }
            if subrole.isEmpty { XCTAssertTrue(window["subrole"] is NSNull) } else { XCTAssertEqual(window["subrole"] as? String, subrole) }
            if let modal { XCTAssertEqual(window["modal"] as? Bool, modal) } else { XCTAssertTrue(window["modal"] is NSNull) }
            XCTAssertEqual(Array((try XCTUnwrap(window["title"] as? String)).utf8), Array("Untrusted \"title\" — cafe\u{301}".utf8))
            XCTAssertEqual(window["truncated"] as? Bool, false)
            XCTAssertEqual(graph.readCount("window", kAXValueAttribute), 0)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextBoundsTitlesAndDoesNotExposeProtectedWindows() throws {
        for mode in ["long-title", "malformed", "secure", "protected", "hidden"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            graph.set("window", kAXTitleAttribute, String(repeating: "👩🏽‍💻", count: 80) as NSString)
            switch mode {
            case "malformed":
                graph.set("window", kAXModalAttribute, NSNumber(value: 2))
                graph.set("window", kAXRoleAttribute, String(repeating: "x", count: 129) as NSString)
                graph.set("window", kAXSubroleAttribute, NSNumber(value: 1))
                graph.set("window", kAXTitleAttribute, NSNumber(value: 1))
            case "secure": graph.set("window", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "protected": graph.set("window", "AXProtectedContent", kCFBooleanTrue)
            case "hidden": graph.set("window", "AXHidden", kCFBooleanTrue)
            default: break
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }))
            if ["secure", "protected", "hidden"].contains(mode) {
                XCTAssertTrue(catalog.jsonObject["window"] is NSNull, mode)
                XCTAssertTrue(catalog.items.isEmpty)
                XCTAssertEqual(graph.readCount("window", kAXTitleAttribute), 0)
            } else {
                let window = try XCTUnwrap(catalog.jsonObject["window"] as? [String: Any])
                XCTAssertEqual(window["truncated"] as? Bool, true)
                if mode == "long-title" {
                    XCTAssertEqual(window["title"] as? String, String(repeating: "👩🏽‍💻", count: 25))
                } else {
                    for key in ["role", "subrole", "title", "modal"] { XCTAssertTrue(window[key] is NSNull, key) }
                }
            }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextRejectsMetadataChangesDuringObservation() throws {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXTitleAttribute, "AXProtectedContent", "AXHidden"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds); graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            graph.set("window", kAXTitleAttribute, "café" as NSString)
            graph.afterRead = { node, name in
                guard node == "destination", name == kAXTitleAttribute else { return }
                if [kAXModalAttribute, "AXProtectedContent", "AXHidden"].contains(attribute) {
                    graph.set("window", attribute, kCFBooleanTrue)
                } else { graph.set("window", attribute, (attribute == kAXTitleAttribute ? "cafe\u{301}" : "AXChanged") as NSString) }
            }
            XCTAssertNil(try ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { true }), attribute)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeWindowContextRejectsWithdrawalDuringTheLastAXReply() throws {
        for mode in ["permission", "deadline", "application"] {
            let graph = AXTextGraph(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", bounds)
            var allowed = true, expired = false
            graph.afterRead = { node, attribute in
                guard node == "window", attribute == kAXModalAttribute, graph.readCount(node, attribute) == 2 else { return }
                switch mode {
                case "permission": allowed = false
                case "deadline": expired = true
                default: graph.applicationIdentity = "replacement-launch"
                }
            }
            let observe = { try ComputerUseNativeControlReader.observe(displayBounds: bounds, windowBounds: bounds,
                access: graph.access, mayAct: { allowed }, now: { Date(timeIntervalSinceReferenceDate: expired ? 1 : 0) }) }
            if mode == "permission" { XCTAssertThrowsError(try observe()) } else { XCTAssertNil(try observe(), mode) }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueUsesBoundsAndNeverReadsEditableValues() throws {
        let graph = AXTextGraph()
        let display = CGRect(x: -1280, y: -200, width: 1280, height: 800)
        let window = CGRect(x: -1100, y: -100, width: 900, height: 600)
        graph.setFrame("window", window)
        graph.setFrame("destination", CGRect(x: -1000, y: 50, width: 500, height: 18))
        graph.setFrame("source", CGRect(x: -1000, y: 100, width: 500, height: 24))
        let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: display, windowBounds: window, access: graph.access, mayAct: { true }))
        XCTAssertEqual(catalog.items.count, 2); XCTAssertFalse(catalog.truncated)
        XCTAssertEqual(catalog.items[0].description, "AXTextField • café")
        XCTAssertEqual(catalog.items[0].bounds1000, [218.75, 312.5, 390.625, 22.5])
        XCTAssertNil(catalog.items[0].enabled, "Missing AXEnabled is unknown, not disabled")
        for name in ["source", "destination"] {
            XCTAssertEqual(graph.readCount(name, kAXValueAttribute), 0)
            XCTAssertEqual(graph.readCount(name, kAXSelectedTextRangeAttribute), 0)
        }
        XCTAssertTrue(graph.writes.isEmpty)
        graph.set("destination", kAXTitleAttribute, String(repeating: "👩🏽‍💻", count: 80) as NSString)
        let clipped = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: display, windowBounds: window, access: graph.access, mayAct: { true }))
        XCTAssertTrue(clipped.truncated, "A clipped label must not look like a complete observation")
        XCTAssertEqual(clipped.items[0].description, "AXTextField • " + String(repeating: "👩🏽‍💻", count: 25))
    }

    func testNativeControlCatalogueExcludesProtectedHiddenAndOffWindowControls() throws {
        for mode in ["secure", "protected", "hidden", "outside", "nonfinite", "disabled-parent"] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window); graph.setFrame("source", CGRect(x: 20, y: 30, width: 200, height: 20))
            graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            switch mode {
            case "secure": graph.set("group", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "protected": graph.set("destination", "AXProtectedContent", kCFBooleanTrue)
            case "hidden": graph.set("destination", "AXHidden", kCFBooleanTrue)
            case "outside": graph.setFrame("destination", CGRect(x: 780, y: 50, width: 100, height: 20))
            case "nonfinite": graph.setFrame("destination", CGRect(x: CGFloat.infinity, y: 50, width: 100, height: 20))
            default: graph.set("group", kAXEnabledAttribute, kCFBooleanFalse)
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }))
            XCTAssertEqual(catalog.items.count, mode == "secure" ? 0 : (mode == "disabled-parent" ? 2 : 1), mode)
            if mode == "disabled-parent" { XCTAssertTrue(catalog.items.allSatisfy { $0.enabled == false }) }
            if ["secure", "protected", "hidden"].contains(mode) { XCTAssertEqual(graph.readCount("destination", kAXTitleAttribute), 0) }
            XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), 0); XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueRejectsChangedScopeAndWithdrawnPermission() throws {
        for mode in ["application", "window", "bounds", "permission", "deadline"] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window); graph.setFrame("destination", CGRect(x: 20, y: 70, width: 200, height: 20))
            var allowed = true, expired = false
            graph.afterRead = { node, attribute in
                guard node == "destination", attribute == kAXTitleAttribute else { return }
                switch mode {
                case "application": graph.applicationIdentity = "different-launch"
                case "window": graph.set("application", kAXFocusedWindowAttribute, graph.element("other-window"))
                case "bounds": graph.setFrame("window", window.offsetBy(dx: 20, dy: 0))
                case "permission": allowed = false
                default: expired = true
                }
            }
            let observe = { try ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access,
                mayAct: { allowed }, now: { Date(timeIntervalSinceReferenceDate: expired ? 1 : 0) }) }
            if mode == "permission" { XCTAssertThrowsError(try observe()) }
            else { XCTAssertNil(try observe(), mode) }
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlCatalogueBoundsCyclesItemsAndCancellation() async throws {
        for buttons in [true, false] {
            let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
            graph.setFrame("window", window)
            var children: [AXUIElement] = [graph.element("window")]
            for index in 0..<140 {
                let name = "item-\(index)"; children.append(graph.addNode(name))
                graph.set(name, kAXRoleAttribute, (buttons ? "AXButton" : "AXGroup") as NSString)
                graph.set(name, kAXTitleAttribute, (String(repeating: "👩🏽‍💻", count: 80) + " instruction text") as NSString)
                graph.setFrame(name, CGRect(x: 20, y: 30, width: 100, height: 20))
            }
            graph.set("window", kAXChildrenAttribute, children as CFArray)
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }))
            XCTAssertTrue(catalog.truncated); XCTAssertEqual(catalog.items.count, buttons ? 16 : 0)
            XCTAssertTrue(catalog.items.allSatisfy { $0.description.utf8.count <= 512 })
            XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 98)
            XCTAssertTrue(graph.writes.isEmpty)
        }
        let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let task = Task { @MainActor in try ComputerUseNativeControlReader.observe(displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(graph.calls.isEmpty)
    }

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

    func testNativePlanningDeadlineDiscardsLateEditsButAllowsCompiledWorkWithoutAnotherPlanner() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started"),
                                                    returned: expectation(description: "planner returned"))
        defer { gate.finish(()) }
        planner.beforeProposal = { _, fields in
            let destination = try XCTUnwrap(fields.first { $0.label == "café" })
            let proposal = ComputerUseTextGoalProposal.edits([
                .init(targetID: destination.snapshot.targetID, mode: .replaceAll, text: "blue")
            ], unchangedTargetIDs: fields.filter { $0.label != "café" }.map { $0.snapshot.targetID })
            await gate.wait()
            return proposal
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory,
            planningWorker: worker, planningTimeout: 0.1)
        do { _ = try await executor.execute(taskID: "late", prompt: "Put \"blue\" in café.", progress: { _ in }); XCTFail("The planner must time out") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
        await fulfillment(of: [gate.started], timeout: 1)
        XCTAssertTrue(graph.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        do { _ = try await executor.execute(taskID: "busy", prompt: "Put \"blue\" in café.", progress: { _ in }); XCTFail("No second planner may start") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        XCTAssertEqual(planner.goals.count, 1)
        guard case .completed = try await executor.execute(taskID: "compiled", prompt: "Set café to \"green\".", progress: { _ in }) else {
            return XCTFail("An exact compiled task must not depend on planning capacity")
        }
        XCTAssertEqual(graph.value("destination"), "green")
        gate.finish(())
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        XCTAssertEqual(graph.value("destination"), "green", "The stale blue proposal cannot overwrite a later authorized edit")
        XCTAssertEqual(planner.goals.count, 1)
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationPlanningDeadlineRetainsExactAnswerOwnershipAndFreshRetry() async throws {
        let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory,
            planningWorker: worker, planningTimeout: 0.1)
        _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
        let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
        let answer = try pending.goal.answering(pending.question, with: "Use café.")
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "answer planner started"),
                                                    returned: expectation(description: "answer planner returned"))
        defer { gate.finish(()) }
        planner.beforeProposal = { _, _ in await gate.wait(); return nil }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Answer planning must time out") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
        await fulfillment(of: [gate.started], timeout: 1)
        XCTAssertNil(try executor.clarification(taskID: "question"))
        XCTAssertTrue(graph.writes.isEmpty)
        do { _ = try await executor.continueClarification(taskID: "other-answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("The expired proposal cannot transfer answer ownership") }
        catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("An exact retry must still wait for the old call") }
        catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
        gate.finish(())
        await fulfillment(of: [gate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        planner.beforeProposal = nil
        graph.set("source", kAXValueAttribute, "fresh source" as NSString)
        graph.set("destination", kAXValueAttribute, "fresh destination" as NSString)
        for _ in 0..<2 {
            guard case .completed = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }) else {
                return XCTFail("The same answer must remain resumable and replay without another edit")
            }
        }
        XCTAssertEqual(planner.goals, [pending.goal, answer, answer])
        XCTAssertEqual(planner.observations.last?.first { $0.label == "café" }?.snapshot.value, "fresh destination")
        XCTAssertEqual(graph.value("destination"), "blue")
        XCTAssertEqual(graph.value("source"), "fresh source")
        XCTAssertEqual(graph.writes.filter { $0.attribute == kAXSelectedTextAttribute }.count, 1)
    }

    func testNativeClarificationDeadlineDoesNotRenewExpiryOrAuthorizeChangedScope() async throws {
        for invalidation in ["expiry", "scope"] {
            let graph = AXTextGraph(), planner = AXClarificationPlanner(), worker = ComputerUsePlanningWorker()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var now = Date(timeIntervalSince1970: 1_000)
            let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory, now: { now },
                planningWorker: worker, planningTimeout: 0.1)
            _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
            let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
            let answer = try pending.goal.answering(pending.question, with: "café")
            let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started \(invalidation)"),
                                                        returned: expectation(description: "planner returned \(invalidation)"))
            defer { gate.finish(()) }
            planner.beforeProposal = { _, _ in await gate.wait(); return nil }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("Planning must time out") }
            catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
            await fulfillment(of: [gate.started], timeout: 1)
            gate.finish(())
            await fulfillment(of: [gate.returned], timeout: 1)
            try await waitForAvailablePlanningWorker(worker)
            planner.beforeProposal = nil
            if invalidation == "expiry" { now = pending.expiresAt.addingTimeInterval(1) }
            else { graph.set("destination", kAXTitleAttribute, "Changed purpose" as NSString) }
            do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question", goal: answer, progress: { _ in }); XCTFail("A retry cannot renew expired or changed authority") }
            catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
            XCTAssertEqual(planner.goals.count, 2)
            XCTAssertTrue(graph.writes.isEmpty)
        }
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

    func testNativeLifecycleEventsRetireSameObjectAuthorityAfterVisibleStateReturns() throws {
        for notification in [kAXTitleChangedNotification, kAXLayoutChangedNotification,
                             kAXFocusedWindowChangedNotification, kAXApplicationDeactivatedNotification,
                             kAXCreatedNotification, kAXRowCountChangedNotification] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            // The application has already returned to identical attributes
            // when the next read begins. The delivered event is the evidence.
            monitor.notify(notification as String, element: graph.element("destination"))
            XCTAssertNil(target.snapshot(targetID: before.targetID), notification as String)
            assertRejected(target, expected: before)
            XCTAssertTrue(graph.writes.isEmpty)
            let fresh = try XCTUnwrap(target.snapshot())
            XCTAssertNotEqual(fresh.targetID, before.targetID); XCTAssertEqual(fresh.value, before.value)
            XCTAssertEqual(try target.replaceSelectedText("!", expected: fresh), true)
            XCTAssertEqual(graph.value("destination"), "old!")
        }
    }

    func testUnrelatedNativeCreationPreservesExactFieldAuthorityAcrossInputBoundaries() throws {
        for notification in [kAXCreatedNotification, kAXWindowCreatedNotification] {
            for unrelated in ["other-window", "source", "other-label"] {
                for stage in ["before-read", "during-read", "capability"] {
                    let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
                    graph.lifecycleFactory = { _ in monitor }
                    let target = ComputerUseAccessibilityTextTarget(access: graph.access)
                    let before = try XCTUnwrap(target.snapshot())
                    var delivered = false
                    func deliver() {
                        guard !delivered else { return }
                        delivered = true
                        monitor.notify(notification as String, element: graph.element(unrelated))
                    }
                    if stage == "before-read" { deliver() }
                    else if stage == "during-read" {
                        graph.afterRead = { element, attribute in
                            if element == "destination", attribute == kAXValueAttribute { deliver() }
                        }
                    } else { graph.onCapabilityQuery = { deliver() } }
                    XCTAssertEqual(target.snapshot(targetID: before.targetID), before, "\(notification):\(unrelated):\(stage)")
                    XCTAssertEqual(try target.replaceSelectedText("🗺️ café", expected: before), true)
                    XCTAssertTrue(delivered)
                    XCTAssertEqual(graph.value("destination"), "old🗺️ café")
                    XCTAssertEqual(graph.value("source"), "source text")
                    XCTAssertFalse(graph.calls.contains { $0.element == unrelated }, "Creation handling only compares retained object identity")
                }
            }
        }
    }

    func testRelatedOrUnscopedNativeCreationStillRetiresRetainedAuthority() throws {
        for notification in [kAXCreatedNotification, kAXWindowCreatedNotification] {
            for related in ["destination", "label", "group", "window", "application"] {
                let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
                graph.set("destination", kAXTitleAttribute, nil)
                graph.lifecycleFactory = { _ in monitor }
                let target = ComputerUseAccessibilityTextTarget(access: graph.access)
                let before = try XCTUnwrap(target.snapshot())
                monitor.notify(notification as String, element: graph.element(related))
                XCTAssertNil(target.snapshot(targetID: before.targetID), "\(notification):\(related)")
                assertRejected(target, expected: before)
                XCTAssertTrue(graph.writes.isEmpty)
                XCTAssertNotEqual(try XCTUnwrap(target.snapshot()).targetID, before.targetID)
            }
        }
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        monitor.record(.init(kind: .created, element: nil))
        XCTAssertNil(target.snapshot(targetID: before.targetID))
        assertRejected(target, expected: before)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testDestroyedNativeObjectsAreNeverQueriedAgainThroughAnyAXBoundary() throws {
        for name in ["destination", "label", "group", "window", "application"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            if name == "label" { graph.set("destination", kAXTitleAttribute, nil) }
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element(name))
            let start = graph.calls.count
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            assertRejected(target, expected: before)
            _ = target.fields(); _ = target.snapshot()
            graph.restoreDestination()
            if name == "label" { graph.set("destination", kAXTitleAttribute, nil) }
            XCTAssertNil(target.snapshot(targetID: before.targetID))
            XCTAssertNil(target.snapshot(), "Retained destroyed objects cannot be revived by readable attributes")
            XCTAssertFalse(graph.calls.dropFirst(start).contains { $0.element == name }, "No read, settable query, timeout or write may use the destroyed \(name)")
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeDestroyedLabelRejectsObservationUntilFreshLabelAuthorityExists() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.set("destination", kAXTitleAttribute, nil)
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let before = try XCTUnwrap(target.snapshot())
        monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element("label"))
        let callCount = graph.calls.count
        XCTAssertNil(target.snapshot())
        assertRejected(target, expected: before)
        XCTAssertFalse(graph.calls.dropFirst(callCount).contains { $0.element == "label" })
        XCTAssertTrue(graph.writes.isEmpty)
        graph.set("destination", kAXTitleUIElementAttribute, graph.element("other-label"))
        let fresh = try XCTUnwrap(target.snapshot())
        XCTAssertNotEqual(fresh.targetID, before.targetID)
        XCTAssertEqual(fresh.value, before.value)
        XCTAssertEqual(try target.replaceSelectedText("!", expected: fresh), true)
        XCTAssertEqual(graph.value("destination"), "old!")
    }

    func testNativeLifecycleDistinguishesTextStateFromLabelMeaning() throws {
        let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
        graph.set("destination", kAXTitleAttribute, nil)
        graph.lifecycleFactory = { _ in monitor }
        let target = ComputerUseAccessibilityTextTarget(access: graph.access)
        let fields = target.fields()
        let destination = try XCTUnwrap(fields.first { $0.label == "café" }).snapshot
        let source = try XCTUnwrap(fields.first { $0.label == "Source" }).snapshot
        graph.set("destination", kAXValueAttribute, "new" as NSString)
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification] {
            monitor.notify(notification as String, element: graph.element("destination"))
        }
        let edited = try XCTUnwrap(target.snapshot(targetID: destination.targetID))
        XCTAssertEqual(edited.targetID, destination.targetID); XCTAssertEqual(edited.value, "new")
        XCTAssertEqual(target.snapshot(targetID: source.targetID), source)
        monitor.notify(kAXValueChangedNotification as String, element: graph.element("label"))
        XCTAssertNil(target.snapshot(targetID: destination.targetID), "A label changed and reverted; its old meaning cannot be reused")
        XCTAssertEqual(target.snapshot(targetID: source.targetID), source, "An unrelated field's exact identity remains intact")
        let refreshed = try XCTUnwrap(target.snapshot())
        monitor.notify(kAXValueChangedNotification as String, element: graph.element("window"))
        XCTAssertNil(target.snapshot(targetID: refreshed.targetID))
        XCTAssertNil(target.snapshot(targetID: source.targetID), "An enclosing context value is not an ordinary edit to either field")
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeLifecycleIgnoresUnusedLabelObjectsWithoutReadingTheirValues() throws {
        for titleObject in ["label", "destination"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.set("destination", kAXTitleUIElementAttribute, graph.element(titleObject))
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), 0, "The explicit title already supplies the planning label")
            monitor.notify(kAXValueChangedNotification as String, element: graph.element(titleObject))
            XCTAssertEqual(target.snapshot(targetID: before.targetID), before)
            if titleObject == "label" {
                monitor.notify(kAXUIElementDestroyedNotification as String, element: graph.element("label"))
                XCTAssertEqual(target.snapshot(targetID: before.targetID), before, "An unused title object carries no edit authority")
            }
            XCTAssertEqual(try target.replaceSelectedText("!", expected: before), true)
            XCTAssertEqual(graph.value("destination"), "old!")
            XCTAssertEqual(graph.readCount("label", kAXValueAttribute), 0)
        }
    }

    func testNativeLifecycleEventsDuringObservationAndCapabilityChecksStopBeforeInput() throws {
        for stage in [kAXValueAttribute, kAXTitleAttribute, "AXIdentifier", "capability"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let target = ComputerUseAccessibilityTextTarget(access: graph.access)
            let before = try XCTUnwrap(target.snapshot())
            var delivered = false
            func deliver() {
                guard !delivered else { return }
                delivered = true
                monitor.notify(kAXLayoutChangedNotification as String, element: graph.element("window"))
            }
            if stage == "capability" { graph.onCapabilityQuery = { deliver() } }
            else { graph.afterRead = { element, attribute in if element == "destination", attribute == stage { deliver() } } }
            if stage == "capability" {
                XCTAssertThrowsError(try target.select(NSRange(location: 0, length: 0), expected: before)) {
                    XCTAssertEqual($0 as? ComputerUseTextEditError, .preconditionChanged)
                }
            } else { XCTAssertNil(target.snapshot(targetID: before.targetID)) }
            XCTAssertTrue(delivered); XCTAssertTrue(graph.writes.isEmpty)
            graph.afterRead = nil; graph.onCapabilityQuery = nil
            assertRejected(target, expected: before)
            XCTAssertNotEqual(try XCTUnwrap(target.snapshot()).targetID, before.targetID)
        }
    }

    func testNativeLifecycleChangesDuringPlanningRejectEditsAndClarificationAnswers() async throws {
        for scenario in ["edit", "clarification"] {
            let graph = AXTextGraph(), monitor = AXFixtureLifecycleMonitor()
            graph.lifecycleFactory = { _ in monitor }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            if scenario == "edit" {
                let planner = AXGraphPlanner()
                planner.beforeProposal = { monitor.notify(kAXLayoutChangedNotification as String, element: graph.element("window")) }
                let executor = ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("No key input") }),
                    mayAct: { true }, journalDirectory: directory, planner: planner,
                    nativeTarget: ComputerUseAccessibilityTextTarget(access: graph.access))
                do { _ = try await executor.execute(taskID: "edit", prompt: "Apply the requested form edit", progress: { _ in }); XCTFail("A lifecycle event must retire planning authority") }
                catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
            } else {
                let planner = AXClarificationPlanner()
                let executor = clarificationExecutor(graph: graph, planner: planner, directory: directory)
                _ = try await executor.execute(taskID: "question", prompt: "Put \"blue\" in the correct field.", progress: { _ in })
                let pending = try XCTUnwrap(executor.clarification(taskID: "question"))
                monitor.notify(kAXTitleChangedNotification as String, element: graph.element("destination"))
                do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: "question",
                    goal: pending.goal.answering(pending.question, with: "café"), progress: { _ in }); XCTFail("An answer cannot revive pre-event references") }
                catch { XCTAssertEqual(error as? ComputerUseNativeTextExecutor.Failure, .invalidClarification) }
                XCTAssertNil(try executor.clarification(taskID: "question")); XCTAssertEqual(planner.goals.count, 1)
            }
            XCTAssertTrue(graph.writes.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testNativeLifecycleOverflowRetiresOldReferencesAndFreshObservationRecovers() throws {
        let graph = AXTextGraph()
        var monitors: [AXFixtureLifecycleMonitor] = []
        graph.lifecycleFactory = { _ in let next = AXFixtureLifecycleMonitor(); monitors.append(next); return next }
        var target: ComputerUseAccessibilityTextTarget? = ComputerUseAccessibilityTextTarget(access: graph.access)
        let first = try XCTUnwrap(target?.snapshot())
        XCTAssertEqual(target?.snapshot()?.targetID, first.targetID); XCTAssertEqual(monitors.count, 1)
        graph.applicationIdentity = "second-launch"
        let second = try XCTUnwrap(target?.snapshot())
        XCTAssertNotEqual(first.targetID, second.targetID); XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].cancellations, 1)
        monitors[0].notify(kAXUIElementDestroyedNotification as String, element: graph.element("destination"))
        XCTAssertEqual(target?.snapshot(targetID: second.targetID), second, "An old source must not invalidate a replacement scope")
        for _ in 0...ComputerUseAXLifecycleInbox.maximumEvents {
            monitors[1].notify(kAXUIElementDestroyedNotification as String, element: graph.element("other-label"))
        }
        let calls = graph.calls.count
        XCTAssertNil(target?.snapshot(targetID: second.targetID))
        XCTAssertEqual(graph.calls.count, calls, "Lost event coverage must stop all AX queries in this scope")
        let fresh = try XCTUnwrap(target?.snapshot(), "A new observation must be able to establish fresh AX authority")
        XCTAssertNotEqual(fresh.targetID, second.targetID)
        XCTAssertEqual(monitors.count, 3)
        XCTAssertEqual(monitors[1].cancellations, 1)
        XCTAssertNil(target?.snapshot(targetID: second.targetID), "An old reference must never revive")
        monitors[1].notify(kAXUIElementDestroyedNotification as String, element: graph.element("destination"))
        XCTAssertEqual(target?.snapshot(targetID: fresh.targetID), fresh)
        XCTAssertThrowsError(try target?.focus(expected: second))
        XCTAssertTrue(graph.writes.isEmpty)
        target = nil
        XCTAssertEqual(monitors[1].cancellations, 1)
        XCTAssertEqual(monitors[2].cancellations, 1)
    }

    func testNativeLifecycleCallbackRegistryOwnsExactRegistrationAndBoundsItsInbox() throws {
        let callbacks = ComputerUseAXLifecycleCallbacks(), source = NSObject()
        let element = AXUIElementCreateApplication(60_000)
        let first = ComputerUseAXLifecycleInbox(), second = ComputerUseAXLifecycleInbox()
        let oldRegistration = callbacks.register(source: source, inbox: first)
        callbacks.deliver(source: source, element: element, notification: kAXTitleChangedNotification as String)
        XCTAssertEqual(first.drain().map(\.kind), [.elementChanged])
        let replacement = callbacks.register(source: source, inbox: second)
        callbacks.remove(oldRegistration)
        callbacks.deliver(source: source, element: element, notification: kAXUIElementDestroyedNotification as String)
        let event = try XCTUnwrap(second.drain().first)
        XCTAssertEqual(event.kind, .destroyed); XCTAssertTrue(CFEqual(try XCTUnwrap(event.element), element))
        callbacks.deliver(source: source, element: element, notification: "UnknownNotification")
        callbacks.deliver(source: source, element: element, notification: kAXSelectedTextChangedNotification as String)
        XCTAssertTrue(second.drain().isEmpty)
        callbacks.remove(replacement)
        callbacks.deliver(source: source, element: element, notification: kAXLayoutChangedNotification as String)
        second.record(.init(kind: .scopeChanged, element: nil))
        XCTAssertTrue(first.drain().isEmpty); XCTAssertTrue(second.drain().isEmpty)
        let overflow = ComputerUseAXLifecycleInbox()
        for _ in 0...ComputerUseAXLifecycleInbox.maximumEvents { overflow.record(.init(kind: .destroyed, element: element)) }
        XCTAssertEqual(overflow.drain().map(\.kind), [.coverageLost])
        XCTAssertEqual(overflow.drain().map(\.kind), [.coverageLost], "Draining must not erase the fact that a destruction event was lost")
        overflow.close(); XCTAssertTrue(overflow.drain().isEmpty)
    }

    private func clarificationExecutor(graph: AXTextGraph, planner: AXClarificationPlanner, directory: URL,
                                       mayAct: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init,
                                       planningWorker: ComputerUsePlanningWorker = ComputerUsePlanningWorker(),
                                       planningTimeout: TimeInterval = ComputerUsePlanningWorker.maximumWait) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: InputInjector(eventPoster: { _ in XCTFail("The AX fixture must not emit keys") }),
            mayAct: mayAct, journalDirectory: directory, planner: planner, now: now,
            nativeTarget: ComputerUseAccessibilityTextTarget(access: graph.access),
            planningWorker: planningWorker, planningTimeout: planningTimeout)
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
    struct Call { let element: String; let operation: String }
    private var names = ["application", "window", "other-window", "group", "other-group", "destination", "source", "label", "other-label", "replacement"]
    private var elements: [String: AXUIElement] = [:]
    private var attributes: [String: [String: CFTypeRef]] = [:]
    private var reads: [(String, String)] = []
    var writes: [Write] = []
    var calls: [Call] = []
    var lifecycleFactory: ((ComputerUseAccessibilityTextTarget.Application) -> any ComputerUseAXLifecycleMonitoring)?
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
                  calls.append(.init(element: name, operation: "read"))
                  reads.append((name, attribute))
                  let value: CFTypeRef? = name == "application" && attribute == kAXFocusedUIElementAttribute ? self.element(focused) : attributes[name]?[attribute]
                  afterRead?(name, attribute)
                  return value
              }, canSet: { [self] attribute, element in
                  calls.append(.init(element: name(element) ?? "unknown", operation: "canSet"))
                  onCapabilityQuery?()
                  return ["destination", "source"].contains(name(element) ?? "")
                      && [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXValueAttribute].contains(attribute)
              }, write: { [self] attribute, value, element in
                  guard let name = name(element) else { return .invalidUIElement }
                  calls.append(.init(element: name, operation: "write"))
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
              }, timeout: { [self] element, _ in calls.append(.init(element: name(element) ?? "unknown", operation: "timeout")) },
              makeLifecycleMonitor: lifecycleFactory)
    }
    func element(_ name: String) -> AXUIElement { elements[name]! }
    func addNode(_ name: String) -> AXUIElement {
        names.append(name); elements[name] = AXUIElementCreateApplication(pid_t(50_000 + names.count))
        return elements[name]!
    }
    func setFrame(_ name: String, _ frame: CGRect) {
        var point = frame.origin, size = frame.size
        set(name, kAXPositionAttribute, AXValueCreate(.cgPoint, &point))
        set(name, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
    }
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

private final class AXFixtureLifecycleMonitor: ComputerUseAXLifecycleMonitoring {
    private let inbox = ComputerUseAXLifecycleInbox()
    private let callbacks = ComputerUseAXLifecycleCallbacks()
    private let source = NSObject()
    private var registration: ComputerUseAXLifecycleCallbacks.Registration!
    private(set) var cancellations = 0
    init() { registration = callbacks.register(source: source, inbox: inbox) }
    func notify(_ notification: String, element: AXUIElement) { callbacks.deliver(source: source, element: element, notification: notification) }
    func record(_ event: ComputerUseAXLifecycleEvent) { inbox.record(event) }
    func drain() -> [ComputerUseAXLifecycleEvent] { inbox.drain() }
    func cancel() { cancellations += 1; callbacks.remove(registration); inbox.close() }
}

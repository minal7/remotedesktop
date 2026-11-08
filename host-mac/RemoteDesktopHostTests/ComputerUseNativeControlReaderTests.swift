import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeControlReaderTests: XCTestCase {
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
            XCTAssertTrue(catalog.truncated); XCTAssertEqual(catalog.items.count, buttons ? 32 : 0)
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

    func testNativeControlsKeepLaterFocusedDocumentControlWithinThirtyTwoItemBudget() throws {
        let (graph, window) = nativeControlsPriorityFixture()
        var prioritizedChildren: [AXUIElement] = [graph.element("destination")]
        for index in 0..<20 {
            let name = "page-control-\(index)"
            let control = graph.element(name)
            graph.set(name, kAXParentAttribute, graph.element("header-inner"))
            prioritizedChildren.append(control)
        }
        prioritizedChildren.append(graph.element("useful-page-control"))
        graph.set("header-inner", kAXChildrenAttribute, prioritizedChildren as CFArray)
        graph.set("page-toolbar", kAXChildrenAttribute, [] as CFArray)

        let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(
            displayBounds: window, windowBounds: window, access: graph.access, mayAct: { true }))
        XCTAssertLessThanOrEqual(catalog.items.count, 32)
        let usefulIndex = try XCTUnwrap(catalog.items.firstIndex { $0.description == "AXButton • Continue" })
        XCTAssertGreaterThan(usefulIndex, 16, "The useful control should survive after earlier controls fill the former budget")
        XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 96)
        XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), 0)
        for index in 0..<20 {
            XCTAssertEqual(graph.readCount("page-control-\(index)", kAXValueAttribute), 0)
        }
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeControlsPrioritizeFocusedDocumentAndKeepFocusedChromeEditor() throws {
        let (graph, window) = nativeControlsPriorityFixture()
        let pageFocused = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
            windowBounds: window, access: graph.access, mayAct: { true }))
        let pageIndex = try XCTUnwrap(pageFocused.items.firstIndex { $0.description == "AXButton • Continue" })
        if let chromeIndex = pageFocused.items.firstIndex(where: { $0.description == "AXButton • Browser control 0" }) {
            XCTAssertLessThan(pageIndex, chromeIndex)
        }
        XCTAssertLessThanOrEqual(pageFocused.items.count, 32)
        XCTAssertTrue(pageFocused.truncated)
        XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 96)
        XCTAssertTrue(graph.writes.isEmpty)

        graph.focused = "browser-address"
        let chromeChildren = (0..<100).map { graph.element("chrome-button-\($0)") }
        graph.set("window", kAXChildrenAttribute,
            ([graph.element("browser-address")] + chromeChildren + [graph.element("page-container")]) as CFArray)
        graph.calls.removeAll()
        let chromeFocused = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
            windowBounds: window, access: graph.access, mayAct: { true }))
        let addressIndex = try XCTUnwrap(chromeFocused.items.firstIndex { $0.description == "AXTextField • Browser address" })
        let firstChromeIndex = try XCTUnwrap(chromeFocused.items.firstIndex { $0.description == "AXButton • Browser control 0" })
        XCTAssertLessThan(addressIndex, firstChromeIndex)
        XCTAssertLessThanOrEqual(chromeFocused.items.count, 32)
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeControlsPrioritizeFocusedEditorBranchBeforeEarlierPageControls() throws {
        let (graph, window) = nativeControlsPriorityFixture()
        // The focused editor and its useful sibling are in a later page group;
        // ordinary page-order traversal spends the 16-item budget on toolbar controls first.
        graph.set("web-area", kAXChildrenAttribute,
            [graph.element("page-toolbar"), graph.element("header-shell")] as CFArray)

        let observation = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
            windowBounds: window, access: graph.access, mayAct: { true }))
        let usefulIndex = try XCTUnwrap(observation.items.firstIndex { $0.description == "AXButton • Continue" },
            "A useful sibling in the focused editor's branch should survive the bounded catalogue")
        let firstToolbarIndex = try XCTUnwrap(observation.items.firstIndex { $0.description == "AXButton • Page control 0" })

        XCTAssertLessThan(usefulIndex, firstToolbarIndex,
            "The path toward the focused editor should be visited before unrelated page branches")
        XCTAssertLessThanOrEqual(observation.items.count, 32)
        XCTAssertTrue(observation.truncated)
        XCTAssertLessThanOrEqual(graph.calls.filter { $0.operation == "timeout" }.count, 96)
        XCTAssertEqual(graph.readCount("destination", kAXValueAttribute), 0,
            "Focused-path prioritization must not read editor text")
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testNativeControlFocusedPathKeepsProtectionAndDisabledAncestors() throws {
        for mode in ["hidden", "protected", "secure", "disabled", "nested"] {
            let (graph, window) = nativeControlsPriorityFixture(nestedUsefulControl: mode == "nested")
            switch mode {
            case "hidden": graph.set("page-container", "AXHidden", kCFBooleanTrue)
            case "protected": graph.set("page-container", "AXProtectedContent", kCFBooleanTrue)
            case "secure": graph.set("page-container", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
            case "disabled": graph.set("page-container", kAXEnabledAttribute, kCFBooleanFalse)
            default: break
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            let useful = catalog.items.first { $0.description == "AXButton • Continue" }
            if ["hidden", "protected", "secure"].contains(mode) {
                XCTAssertNil(useful, mode)
                XCTAssertEqual(catalog.items.first?.description, "AXButton • Browser control 0", mode)
            } else if mode == "disabled" {
                XCTAssertEqual(useful?.enabled, false, "A disabled focused ancestor must remain disabled")
            } else {
                XCTAssertNotNil(useful, "Controls nested under a web area remain in the outer document traversal")
            }
            XCTAssertLessThanOrEqual(catalog.items.count, 32)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlFocusedPathFallsBackOnForeignIncompleteOrCyclicAncestry() throws {
        for mode in ["foreign", "incomplete", "cycle"] {
            let (graph, window) = nativeControlsPriorityFixture()
            switch mode {
            case "foreign": graph.set("page-container", kAXParentAttribute, graph.element("other-window"))
            case "incomplete": graph.set("page-container", kAXParentAttribute, nil)
            default:
                graph.set("page-container", kAXParentAttribute, graph.element("header-shell"))
                graph.set("header-shell", kAXParentAttribute, graph.element("page-container"))
            }
            let catalog = try XCTUnwrap(ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            XCTAssertEqual(catalog.items.first?.description, "AXButton • Browser control 0", mode)
            XCTAssertFalse(catalog.items.contains { $0.description == "AXButton • Continue" }, mode)
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    func testNativeControlFocusedPathChangeDuringPrioritizedReadRejectsMixedCatalogue() throws {
        for mode in ["focus", "parent", "hidden-container"] {
            let (graph, window) = nativeControlsPriorityFixture()
            var changed = false
            graph.afterRead = { element, attribute in
                guard !changed, element == "useful-page-control", attribute == kAXTitleAttribute else { return }
                changed = true
                if mode == "focus" { graph.focused = "browser-address" }
                else if mode == "hidden-container" { graph.set("page-container", "AXHidden", kCFBooleanTrue) }
                else { graph.set("page-container", kAXParentAttribute, graph.element("other-group")) }
            }
            XCTAssertNil(try ComputerUseNativeControlReader.observe(displayBounds: window,
                windowBounds: window, access: graph.access, mayAct: { true }), mode)
            XCTAssertTrue(changed, "The useful page control was read before the scope changed")
            XCTAssertTrue(graph.writes.isEmpty)
        }
    }

    private func nativeControlsPriorityFixture(nestedUsefulControl: Bool = false) -> (AXTextGraph, CGRect) {
        let graph = AXTextGraph(), window = CGRect(x: 0, y: 0, width: 900, height: 700)
        graph.setFrame("window", window)
        var chrome: [AXUIElement] = []
        for index in 0..<100 {
            let name = "chrome-button-\(index)"
            let element = graph.addNode(name)
            chrome.append(element)
            graph.set(name, kAXRoleAttribute, kAXButtonRole as NSString)
            graph.set(name, kAXTitleAttribute, "Browser control \(index)" as NSString)
            graph.set(name, kAXParentAttribute, graph.element("window"))
            graph.setFrame(name, CGRect(x: 10, y: 10 + CGFloat(index % 20) * 24, width: 140, height: 20))
        }
        let address = graph.addNode("browser-address")
        graph.set("browser-address", kAXRoleAttribute, kAXTextFieldRole as NSString)
        graph.set("browser-address", kAXTitleAttribute, "Browser address" as NSString)
        graph.set("browser-address", kAXValueAttribute, "" as NSString)
        graph.set("browser-address", "AXEditable", kCFBooleanTrue)
        graph.set("browser-address", kAXParentAttribute, graph.element("window"))
        graph.setFrame("browser-address", CGRect(x: 20, y: 410, width: 500, height: 24))
        graph.setSelection("browser-address", NSRange(location: 0, length: 0))
        _ = graph.addNode("web-area")
        graph.set("web-area", kAXRoleAttribute, "AXWebArea" as NSString)
        graph.set("web-area", kAXDocumentAttribute, "https://example.test/" as NSString)
        _ = graph.addNode("page-container")
        graph.set("page-container", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("page-container", kAXParentAttribute, graph.element("window"))
        graph.set("page-container", kAXChildrenAttribute, [graph.element("web-area")] as CFArray)
        graph.setFrame("page-container", CGRect(x: 0, y: 450, width: 900, height: 240))
        graph.set("web-area", kAXParentAttribute, graph.element("page-container"))
        graph.setFrame("web-area", CGRect(x: 0, y: 450, width: 900, height: 240))
        _ = graph.addNode("header-shell")
        graph.set("header-shell", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("header-shell", kAXParentAttribute, graph.element("web-area"))
        _ = graph.addNode("header-inner")
        graph.set("header-inner", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("header-inner", kAXParentAttribute, graph.element("header-shell"))
        graph.set("destination", kAXRoleAttribute, kAXTextFieldRole as NSString)
        graph.set("destination", kAXTitleAttribute, "Search term" as NSString)
        graph.set("destination", kAXValueAttribute, "" as NSString)
        graph.set("destination", "AXEditable", kCFBooleanTrue)
        graph.set("destination", kAXParentAttribute, graph.element("header-inner"))
        graph.setFrame("destination", CGRect(x: 240, y: 480, width: 300, height: 24))
        graph.setSelection("destination", NSRange(location: 0, length: 0))
        let useful = graph.addNode("useful-page-control")
        graph.set("useful-page-control", kAXRoleAttribute, kAXButtonRole as NSString)
        graph.set("useful-page-control", kAXTitleAttribute, "Continue" as NSString)
        graph.setFrame("useful-page-control", CGRect(x: 600, y: 480, width: 120, height: 28))
        if nestedUsefulControl {
            let nested = graph.addNode("nested-web-area")
            graph.set("nested-web-area", kAXRoleAttribute, "AXWebArea" as NSString)
            graph.set("nested-web-area", kAXParentAttribute, graph.element("header-inner"))
            graph.set("nested-web-area", kAXChildrenAttribute, [useful] as CFArray)
            graph.set("useful-page-control", kAXParentAttribute, nested)
            graph.set("header-inner", kAXChildrenAttribute, [graph.element("destination"), nested] as CFArray)
        } else {
            graph.set("useful-page-control", kAXParentAttribute, graph.element("header-inner"))
            graph.set("header-inner", kAXChildrenAttribute, [graph.element("destination"), useful] as CFArray)
        }
        graph.set("header-shell", kAXChildrenAttribute, [graph.element("header-inner")] as CFArray)
        let pageToolbar = graph.addNode("page-toolbar")
        graph.set("page-toolbar", kAXRoleAttribute, kAXGroupRole as NSString)
        graph.set("page-toolbar", kAXParentAttribute, graph.element("web-area"))
        var laterPageControls: [AXUIElement] = []
        for index in 0..<20 {
            let name = "page-control-\(index)"
            let control = graph.addNode(name)
            laterPageControls.append(control)
            graph.set(name, kAXRoleAttribute, kAXButtonRole as NSString)
            graph.set(name, kAXTitleAttribute, "Page control \(index)" as NSString)
            graph.set(name, kAXParentAttribute, pageToolbar)
            graph.setFrame(name, CGRect(x: 250 + CGFloat(index % 5) * 80,
                y: 520 + CGFloat(index / 5) * 30, width: 70, height: 24))
        }
        graph.set("page-toolbar", kAXChildrenAttribute, laterPageControls as CFArray)
        graph.set("web-area", kAXChildrenAttribute, [graph.element("header-shell"), pageToolbar] as CFArray)
        graph.set("window", kAXChildrenAttribute, (chrome + [address, graph.element("page-container")]) as CFArray)
        graph.focused = "destination"
        return (graph, window)
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

    var access: ComputerUseNativeControlReader.Access {
        .init(frontmost: { [self] in
            applicationAvailable ? .init(identity: applicationIdentity, root: element("application")) : nil
        }, read: { [self] attribute, element in
            guard let name = name(element) else { return nil }
            calls.append(.init(element: name, operation: "read"))
            reads.append((name, attribute))
            let value: CFTypeRef? = name == "application" && attribute == kAXFocusedUIElementAttribute
                ? self.element(focused) : attributes[name]?[attribute]
            afterRead?(name, attribute)
            return value
        }, timeout: { [self] element, _ in
            calls.append(.init(element: name(element) ?? "unknown", operation: "timeout"))
        })
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

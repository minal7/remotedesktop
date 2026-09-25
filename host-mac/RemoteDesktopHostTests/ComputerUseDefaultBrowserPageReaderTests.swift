import ApplicationServices
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseDefaultBrowserPageReaderTests: XCTestCase {
    func testReadsMainPageTextAndControlsButExcludesSecureAndIframeContent() throws {
        let graph = PageAXGraph()
        graph.makePage()
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        let observation = try XCTUnwrap(reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
        XCTAssertEqual(observation.url, "https://drive.google.com/drive/my-drive")
        XCTAssertTrue(observation.renderedAXText.contains("Quarterly report"))
        XCTAssertFalse(observation.renderedAXText.contains("password-secret"))
        XCTAssertFalse(observation.renderedAXText.contains("iframe-only secret"))
        XCTAssertTrue(observation.iframeContentMayBeOmitted)
        XCTAssertEqual(observation.controls.map(\.label), ["Open file"])
        XCTAssertFalse(graph.reads.contains(where: { $0 == ("secure", kAXValueAttribute as String) }))
        XCTAssertNotNil(reader.retainedControl(observationID: observation.id, controlID: observation.controls[0].id,
                                              application: graph.identity, window: graph.window))
        XCTAssertTrue(graph.writes.isEmpty)
    }

    func testRejectsForeignApplicationAndForeignFocusedWindow() throws {
        for mode in ["app", "window"] {
            let graph = PageAXGraph(); graph.makePage()
            if mode == "app" { graph.frontmostIdentity = graph.otherIdentity }
            else { graph.focusedWindow = graph.otherWindow }
            let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
            XCTAssertNil(try reader.read(window: graph.window, application: graph.identity, mayAct: { true }), mode)
        }
    }

    func testRejectsReplacedWebAreaDuringObservation() throws {
        let graph = PageAXGraph(); graph.makePage()
        graph.afterRead = { name, attr in
            if name == "web" && attr == "AXURL" && !graph.didReplace {
                graph.didReplace = true
                graph.set("window", kAXChildrenAttribute, [graph.element("web"), graph.element("new-web")] as CFArray)
                graph.set("new-web", kAXRoleAttribute, "AXWebArea" as NSString)
                graph.set("new-web", "AXURL", "https://drive.google.com/other" as NSString)
                graph.set("new-web", kAXChildrenAttribute, [] as CFArray)
            }
        }
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        XCTAssertNil(try reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
    }

    func testBoundsRenderedAXTextAndMarksTruncation() throws {
        let graph = PageAXGraph(); graph.makePage(text: String(repeating: "é", count: 5_000))
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        let result = try XCTUnwrap(reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
        XCTAssertLessThanOrEqual(result.renderedAXText.utf8.count, 8_192)
        XCTAssertTrue(result.truncated)
    }

    func testRetainedControlCannotCrossWindowOrApplication() throws {
        let graph = PageAXGraph(); graph.makePage()
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        let result = try XCTUnwrap(reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
        let id = try XCTUnwrap(result.controls.first?.id)
        XCTAssertNil(reader.retainedControl(observationID: result.id, controlID: id,
                                            application: graph.otherIdentity, window: graph.window))
        XCTAssertNil(reader.retainedControl(observationID: result.id, controlID: id,
                                            application: graph.identity, window: graph.otherWindow))
    }

    func testHiddenAncestorCannotSupplyPageOrControlEvidence() throws {
        let graph = PageAXGraph(); graph.makePage()
        graph.set("window", "AXHidden", kCFBooleanTrue)
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        XCTAssertNil(try reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
    }

    func testPageDiscoveryFailsClosedWhenNodeBudgetDropsUnseenSibling() throws {
        let graph = PageAXGraph(); graph.makePage()
        var children: [AXUIElement] = [graph.element("web")]
        for index in 0 ..< 300 {
            let name = "filler-\(index)"
            let node = graph.element(name)
            graph.set(name, kAXRoleAttribute, "AXGroup" as NSString)
            graph.set(name, kAXChildrenAttribute, [] as CFArray)
            children.append(node)
        }
        // This second outer page falls beyond the discovery queue cap. The
        // first page must not be treated as unique after dropping that branch.
        let unseen = graph.element("unseen-web")
        graph.set("unseen-web", kAXRoleAttribute, "AXWebArea" as NSString)
        graph.set("unseen-web", "AXURL", "https://drive.google.com/other" as NSString)
        children.append(unseen)
        graph.set("window", kAXChildrenAttribute, children as CFArray)
        let reader = ComputerUseDefaultBrowserPageReader(access: graph.access)
        XCTAssertNil(try reader.read(window: graph.window, application: graph.identity, mayAct: { true }))
    }
}

@MainActor
private final class PageAXGraph {
    private var refs: [String: AXUIElement] = [:]
    private var attrs: [String: [String: CFTypeRef]] = [:]
    var writes: [String] = []
    var reads: [(String, String)] = []
    var afterRead: ((String, String) -> Void)?
    var didReplace = false
    let identity = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 93001,
                                                  launchGeneration: 9)!
    let otherIdentity = ComputerUseApplicationIdentity(bundleIdentifier: "com.google.Chrome", processIdentifier: 93002,
                                                       launchGeneration: 10)!
    lazy var window = element("window")
    lazy var otherWindow = element("other-window")
    var frontmostIdentity: ComputerUseApplicationIdentity
    lazy var focusedWindow = element("window")

    init() {
        frontmostIdentity = identity
        for name in ["root", "window", "other-window", "web", "text", "button", "secure", "iframe", "iframe-text", "new-web"] {
            refs[name] = AXUIElementCreateApplication(pid_t(93_100 + (refs.count * 2)))
        }
    }

    func element(_ key: String) -> AXUIElement {
        if let value = refs[key] { return value }
        let value = AXUIElementCreateApplication(pid_t(93_100 + (refs.count * 2)))
        refs[key] = value
        return value
    }

    func set(_ node: String, _ attribute: String, _ value: CFTypeRef) { attrs[node, default: [:]][attribute] = value }
    func set(_ node: String, _ attribute: CFString, _ value: CFTypeRef) { set(node, attribute as String, value) }

    func makePage(text: String = "Quarterly report") {
        set("root", kAXFocusedWindowAttribute, element("window"))
        set("window", kAXRoleAttribute, "AXWindow" as NSString)
        set("window", kAXChildrenAttribute, [element("web")] as CFArray)
        set("web", kAXRoleAttribute, "AXWebArea" as NSString)
        set("web", "AXURL", "https://drive.google.com/drive/my-drive" as NSString)
        set("web", kAXChildrenAttribute, [element("text"), element("button"), element("secure"), element("iframe")] as CFArray)
        set("text", kAXRoleAttribute, "AXStaticText" as NSString); set("text", kAXValueAttribute, text as NSString)
        set("button", kAXRoleAttribute, "AXButton" as NSString); set("button", kAXTitleAttribute, "Open file" as NSString)
        set("secure", kAXRoleAttribute, "AXTextField" as NSString); set("secure", kAXSubroleAttribute, kAXSecureTextFieldSubrole as NSString)
        set("secure", kAXValueAttribute, "password-secret" as NSString)
        set("iframe", kAXRoleAttribute, "AXWebArea" as NSString)
        set("iframe", kAXChildrenAttribute, [element("iframe-text")] as CFArray)
        set("iframe-text", kAXRoleAttribute, "AXStaticText" as NSString); set("iframe-text", kAXValueAttribute, "iframe-only secret" as NSString)
    }

    var access: ComputerUseDefaultBrowserPageReader.Access {
        .init(frontmost: { [self] in (frontmostIdentity, element("root")) }, read: { [self] attr, ref in
            guard let node = refs.first(where: { CFEqual($0.value, ref) })?.key else { return nil }
            reads.append((node, attr))
            let result: CFTypeRef?
            if node == "root", attr == (kAXFocusedWindowAttribute as String) { result = focusedWindow }
            else { result = attrs[node]?[attr] }
            afterRead?(node, attr)
            return result
        }, timeout: { _, _ in })
    }
}

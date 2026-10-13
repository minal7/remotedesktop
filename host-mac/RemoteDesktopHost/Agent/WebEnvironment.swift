import CryptoKit
import Foundation
import ImageIO

typealias AgentWebFileFinder = @MainActor (String, String?, String?) async throws -> [AgentFileCandidate]
typealias AgentWebFileResolver = @MainActor ([String]) async throws -> [AgentWebFile]

@MainActor
final class WebEnvironment: AgentEnvironment {
    private struct PageSnapshot: Decodable {
        struct Focus: Decodable { let id: Int; let role: String; let name: String; let value_prefix: String; let selection: [Int] }
        let documentId: String
        let url: String
        let title: String
        let pageText: String
        let elements: [AgentElement]
        let focus: Focus?
        let viewport: [Double]
        let authorityDigest: String
    }
    private struct PageReply: Decodable {
        let screenshot: String?
        let documentId: String?
        let url: String?
        let title: String?
        let pageText: String?
        let elements: [AgentElement]?
        let focus: PageSnapshot.Focus?
        let strategy: String?
        let names: [String]?
    }

    private let transport: SafariBridgeTransport
    private let task: String
    private let taskID: String
    private let startURL: String?
    private let initialBinding: SafariBridgeTabBinding?
    private let finder: AgentWebFileFinder?
    private let fileResolver: AgentWebFileResolver?
    private let mayAct: () -> Bool
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var binding: SafariBridgeTabBinding?
    private var latestDocumentID: String?
    private var stopped = false
    private var suspended = false

    init(taskID: String, task: String, startURL: String? = nil, initialBinding: SafariBridgeTabBinding? = nil,
         transport: SafariBridgeTransport? = nil, finder: AgentWebFileFinder? = nil,
         fileResolver: AgentWebFileResolver? = nil, mayAct: @escaping () -> Bool = { true }) {
        self.taskID = taskID; self.task = task; self.startURL = startURL; self.initialBinding = initialBinding
        self.transport = transport ?? SafariBridgeTransport(); self.finder = finder; self.fileResolver = fileResolver
        self.mayAct = mayAct
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        try checkActive(); try await ensureBound(); try checkActive()
        let before = try await snapshot(); try checkActive()
        try Self.validateViewport(before.viewport)
        let png = try await capturePNG(); try checkActive()
        let after = try await snapshot(); try checkActive()
        try Self.validateViewport(after.viewport)
        guard Self.sameLayout(before, after) else { throw AgentEnvironmentError.scopeChanged }
        let imageDimensions = Self.pngDimensions(png)
        guard imageDimensions.width.isFinite, imageDimensions.height.isFinite, imageDimensions.width > 0, imageDimensions.height > 0 else {
            throw AgentEnvironmentError.unavailable("Safari returned an invalid screenshot size.")
        }
        let sourceWidth = max(1, before.viewport[0]), sourceHeight = max(1, before.viewport[1])
        let sx = Double(imageDimensions.width) / sourceWidth, sy = Double(imageDimensions.height) / sourceHeight
        let scaledElements = after.elements.map { element in
            AgentElement(id: element.id, role: element.role, name: element.name, value: element.value,
                state: element.state, bbox: AgentBoundingBox(x: element.bbox.x * sx, y: element.bbox.y * sy,
                    width: element.bbox.width * sx, height: element.bbox.height * sy), inView: element.inView)
        }
        let webElements = try AgentWebObservation.pageTextElement(after.pageText,
            screenshotWidth: Double(imageDimensions.width), screenshotHeight: Double(imageDimensions.height),
            bridgeElements: scaledElements)
        let elements = Self.tokenBoundElements(webElements, focusID: after.focus?.id)
        let focus = after.focus.map { AgentFocus(id: $0.id, role: $0.role, name: $0.name,
            valuePrefix: $0.value_prefix, selection: AgentSelection(start: $0.selection.first ?? 0,
                end: $0.selection.dropFirst().first ?? 0)) }
        let observation = AgentObservation(task: context.task, surface: .web(url: after.url, title: after.title),
            screenshot: png.base64EncodedString(), elements: elements, focus: focus,
            history: context.history, budget: context.budget)
        try observation.validate(); latestDocumentID = after.documentId
        return AgentFrame(observation: observation,
            scope: AgentScope(taskID: taskID, kind: .web, identity: "\(binding!.tabId):\(binding!.windowId)"),
            authorityDigest: after.authorityDigest)
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        try checkFrame(frame); try await Task.checkCancellation()
        let page = try await snapshot(); try checkActive()
        try checkPage(page, matches: frame)
        if case let .openURL(url) = action, !SafariBridgeCommand.isAllowedURL(url) { throw AgentEnvironmentError.unsupportedAction }
        let currentFrame = try Self.refreshedFrame(from: frame, page: page)
        if case .type(nil, _, _) = action { try Self.requireSameFocus(frame.observation.focus, page.focus, elements: page.elements) }
        if case .key = action { try Self.requireSameFocus(frame.observation.focus, page.focus, elements: page.elements) }
        if case .findFiles = action { return AgentResolvedAction(action: action, frame: currentFrame, targets: []) }
        let pairs = try AgentWebObservation.targetPairs(for: action, in: frame.observation.elements)
        let imageDimensions = Self.pngDimensions(Data(base64Encoded: frame.observation.screenshot) ?? Data())
        let freshTargets = try AgentWebObservation.resolveTargets(pairs, currentElements: page.elements,
            viewport: page.viewport, screenshotSize: [imageDimensions.width, imageDimensions.height])
        return AgentResolvedAction(action: action, frame: currentFrame, targets: freshTargets)
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        try checkFrame(resolved.frame); try await Task.checkCancellation()
        // Every action is fenced against the current task tab, document, and URL,
        // including actions whose schema has no explicit target.
        let fresh = try await snapshot(); try checkActive(); try checkPage(fresh, matches: resolved.frame)
        guard let expectedAuthorityDigest = resolved.frame.authorityDigest,
              Self.isSHA256Digest(expectedAuthorityDigest), fresh.authorityDigest == expectedAuthorityDigest else {
            throw AgentEnvironmentError.targetChanged
        }
        for old in resolved.targets {
            guard let current = fresh.elements.first(where: { $0.id == old.id }) else { throw AgentEnvironmentError.targetGone }
            try AgentWebObservation.requireSameTarget(old, current)
        }
        try await Task.checkCancellation(); try checkActive()
        if case let .findFiles(query, kind, modifiedAfter) = resolved.action {
            guard let finder else { throw AgentEnvironmentError.unavailable("Local file search is unavailable.") }
            let candidates = try await finder(query, kind, modifiedAfter); try checkActive(); try await Task.checkCancellation()
            let payload = candidates.map { ["id": $0.id, "name": $0.name, "kind": $0.kind ?? "", "modified_at": $0.modifiedAt.map(ISO8601DateFormatter().string(from:)) ?? ""] }
            let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return .init(status: .ok, result: String(decoding: encoded, as: UTF8.self))
        }
        if case let .openURL(url) = resolved.action {
            _ = try await send(.navigate, url: url); try checkActive()
            latestDocumentID = nil
            return .init(status: .ok, result: "Navigated the task tab.")
        }
        if case let .wait(seconds) = resolved.action {
            _ = try await send(.wait, payload: ["seconds": seconds]); try checkActive()
            return .init(status: .ok, result: "Waited for page activity to settle.")
        }
        if case let .setFiles(target, ids) = resolved.action {
            guard !ids.isEmpty, Set(ids).count == ids.count, let fileResolver else {
                throw AgentEnvironmentError.unavailable("Local file selection is unavailable.")
            }
            let targetInfo = try Self.targetPayload(target, targets: resolved.targets, screenshot: resolved.frame.observation.screenshot)
            let files = try await fileResolver(ids); try checkActive(); try await Task.checkCancellation()
            guard files.map(\.id) == ids else { throw AgentEnvironmentError.targetChanged }
            let total = files.reduce(0) { $0 + $1.bytes.count }
            guard total <= 50 * 1024 * 1024, files.allSatisfy({ !$0.name.isEmpty && $0.bytes.count <= 20 * 1024 * 1024 }) else {
                throw AgentEnvironmentError.unavailable("Selected files exceed the transfer limit.")
            }
            let transferID = UUID().uuidString.lowercased()
            let metadata = files.map { file -> [String: Any] in
                let digest = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
                return ["name": file.name, "mimeType": file.mimeType, "lastModified": file.lastModified.timeIntervalSince1970 * 1000,
                        "size": file.bytes.count, "sha256": digest]
            }
            _ = try await send(.setFiles, payload: ["stage": "begin", "transferId": transferID,
                "targetId": targetInfo.id, "expected": targetInfo.expected, "point": targetInfo.point as Any? ?? NSNull(),
                "expectedAuthorityDigest": expectedAuthorityDigest, "files": metadata])
            for (fileIndex, file) in files.enumerated() {
                var offset = 0, index = 0
                while offset < file.bytes.count {
                    try checkActive(); try await Task.checkCancellation()
                    let end = min(offset + 192 * 1024, file.bytes.count)
                    let part = file.bytes.subdata(in: offset..<end).base64EncodedString()
                    _ = try await send(.setFiles, payload: ["stage": "chunk", "transferId": transferID,
                        "fileIndex": fileIndex, "index": index, "base64": part])
                    offset = end; index += 1
                }
            }
            try checkActive(); try await Task.checkCancellation()
            let result = try await send(.setFiles, payload: ["stage": "finish", "transferId": transferID])
            guard ["input", "drop", "main_click"].contains(result.strategy ?? "") else {
                throw AgentEnvironmentError.unavailable("The page did not accept the selected file.")
            }
            return .init(status: .ok, result: "Supplied selected file(s) to the page using a verified transfer.")
        }
        if case .type(nil, _, _) = resolved.action { try Self.requireSameFocus(resolved.frame.observation.focus, fresh.focus, elements: fresh.elements) }
        if case .key = resolved.action { try Self.requireSameFocus(resolved.frame.observation.focus, fresh.focus, elements: fresh.elements) }
        let payload = try Self.payload(for: resolved.action, targets: resolved.targets, focus: fresh.focus,
                                       screenshot: resolved.frame.observation.screenshot,
                                       expectedAuthorityDigest: expectedAuthorityDigest)
        let operation = try Self.operation(for: resolved.action)
        _ = try await send(operation, payload: payload); try checkActive()
        return .init(status: .ok, result: "Action dispatched to the task tab.")
    }

    func stop() async {
        guard !stopped else { return }; stopped = true
        if binding != nil { _ = try? await transport.perform(SafariBridgeCommand(taskToken: token, operation: .endTask)) }
        await transport.endTask(taskToken: token); binding = nil
    }

    func suspend() async { suspended = true }
    func resume() async throws {
        guard !stopped else { throw AgentEnvironmentError.unavailable("The web task has stopped.") }
        suspended = false
        try await ensureBound()
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw AgentEnvironmentError.unavailable("The web task has stopped.") }
        guard !suspended else { throw AgentEnvironmentError.unavailable("The web task is paused.") }
        guard mayAct() else { throw CancellationError() }
    }
    private func checkFrame(_ frame: AgentFrame) throws {
        try checkActive()
        guard frame.scope.taskID == taskID, frame.scope.kind == .web, let binding,
              frame.scope.identity == "\(binding.tabId):\(binding.windowId)" else { throw AgentEnvironmentError.scopeChanged }
    }
    private func checkPage(_ page: PageSnapshot, matches frame: AgentFrame) throws {
        guard page.documentId == latestDocumentID, page.url == surfaceURL(frame.observation.surface) else { throw AgentEnvironmentError.scopeChanged }
    }
    private func ensureBound() async throws {
        try checkActive(); guard binding == nil else { return }
        try await transport.startTask(taskToken: token, registerHelperIfNeeded: true); try checkActive()
        if let initialBinding {
            let ping = SafariBridgeCommand(taskToken: token, operation: .ping, tabId: initialBinding.tabId,
                windowId: initialBinding.windowId, nonce: UUID().uuidString)
            let result = try await transport.perform(ping); try checkActive()
            guard let tabId = result.tabId, let windowId = result.windowId else { throw AgentEnvironmentError.scopeChanged }
            binding = SafariBridgeTabBinding(tabId: tabId, windowId: windowId)
        } else if let startURL {
            let open = try SafariBridgeCommand(taskToken: token, operation: .openTab, url: startURL)
            let result = try await transport.perform(open); try checkActive()
            guard let tabId = result.tabId, let windowId = result.windowId else { throw AgentEnvironmentError.unavailable("Safari did not open a task tab.") }
            binding = SafariBridgeTabBinding(tabId: tabId, windowId: windowId)
        } else { throw AgentEnvironmentError.unavailable("A task tab or starting URL is required.") }
    }
    private func snapshot() async throws -> PageSnapshot {
        try checkActive()
        guard let binding else { throw AgentEnvironmentError.scopeChanged }
        let command = SafariBridgeCommand(taskToken: token, operation: .snapshot, tabId: binding.tabId,
            windowId: binding.windowId, payload: ["maxBytes": 65536, "viewportOnly": false])
        let result = try await transport.perform(command); try checkActive()
        guard result.matches(command) else { throw AgentEnvironmentError.unavailable("Safari returned an unrelated page snapshot.") }
        guard result.status == .ok, let resultJSON = result.resultJSON else {
            if let error = result.error { throw Self.environmentError(error) }
            throw AgentEnvironmentError.unavailable("Safari rejected the page snapshot.")
        }
        do {
            let page = try JSONDecoder().decode(PageSnapshot.self, from: Data(resultJSON.utf8))
            try Self.validateViewport(page.viewport)
            guard AgentWebObservation.validBridgeElementIDs(page.elements) else {
                throw AgentEnvironmentError.unavailable("Safari returned invalid page element identities.")
            }
            guard Self.isSHA256Digest(page.authorityDigest) else { throw AgentEnvironmentError.unavailable("Safari returned an invalid page authority digest.") }
            return page
        }
        catch { throw AgentEnvironmentError.unavailable("Safari returned an invalid page snapshot.") }
    }
    private func capturePNG() async throws -> Data {
        try checkActive(); guard let binding else { throw AgentEnvironmentError.scopeChanged }
        let result = try await transport.perform(SafariBridgeCommand(taskToken: token, operation: .captureVisibleTab,
            tabId: binding.tabId, windowId: binding.windowId)); try checkActive()
        guard let resultJSON = result.resultJSON, let object = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: String],
              let base64 = object["screenshot"], let png = Data(base64Encoded: base64),
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw AgentEnvironmentError.unavailable("Safari could not capture the task tab.") }
        return png
    }
    private func send(_ operation: SafariBridgeOperation, url: String? = nil, payload: [String: Any]? = nil) async throws -> PageReply {
        try checkActive(); guard let binding else { throw AgentEnvironmentError.scopeChanged }
        let command = SafariBridgeCommand(taskToken: token, operation: operation, tabId: binding.tabId,
            windowId: binding.windowId, url: url, payload: payload)
        let result = try await transport.perform(command); try checkActive()
        guard result.matches(command) else { throw AgentEnvironmentError.unavailable("Safari returned an unrelated page operation result.") }
        guard result.status == .ok else {
            if let error = result.error { throw Self.environmentError(error) }
            throw AgentEnvironmentError.unavailable("Safari rejected the page operation.")
        }
        guard let resultJSON = result.resultJSON else { return PageReply(screenshot: nil, documentId: result.documentId,
            url: nil, title: nil, pageText: nil, elements: nil, focus: nil, strategy: nil, names: nil) }
        do { return try JSONDecoder().decode(PageReply.self, from: Data(resultJSON.utf8)) }
        catch { throw AgentEnvironmentError.unavailable("Safari returned an invalid page operation result.") }
    }
    private func surfaceURL(_ surface: AgentSurface) -> String? { if case let .web(url, _) = surface { return url }; return nil }
    private static func environmentError(_ error: SafariBridgeError) -> AgentEnvironmentError {
        switch error {
        case .credentialHandoff: .credentialHandoff
        case .targetGone: .targetGone
        case .targetChanged, .staleTask: .targetChanged
        case .targetCovered: .targetCovered
        case .disabledTarget: .disabledTarget
        case .wrongTab, .inactiveTab: .scopeChanged
        default: .unavailable("Safari rejected the page operation (\(error.rawValue)).")
        }
    }

    private static func sameLayout(_ a: PageSnapshot, _ b: PageSnapshot) -> Bool {
        guard a.documentId == b.documentId, a.url == b.url, a.pageText == b.pageText,
              a.focus?.id == b.focus?.id, a.focus?.role == b.focus?.role, a.focus?.name == b.focus?.name,
              a.focus?.value_prefix == b.focus?.value_prefix, a.focus?.selection == b.focus?.selection,
              a.viewport == b.viewport, a.authorityDigest == b.authorityDigest,
              a.elements.count == b.elements.count else { return false }
        return zip(a.elements, b.elements).allSatisfy {
            $0.id == $1.id && $0.role == $1.role && $0.name == $1.name && $0.value == $1.value && $0.bbox == $1.bbox && $0.state == $1.state
        }
    }
    private static func validateViewport(_ viewport: [Double]) throws {
        guard viewport.count == 2, viewport.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw AgentEnvironmentError.unavailable("Safari returned an invalid viewport size.")
        }
    }
    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func refreshedFrame(from frame: AgentFrame, page: PageSnapshot) throws -> AgentFrame {
        let dimensions = pngDimensions(Data(base64Encoded: frame.observation.screenshot) ?? Data())
        let sx = Double(dimensions.width) / max(1, page.viewport[0]), sy = Double(dimensions.height) / max(1, page.viewport[1])
        let elements = page.elements.map { e in AgentElement(id: e.id, role: e.role, name: e.name, value: e.value,
            state: e.state, bbox: AgentBoundingBox(x: e.bbox.x * sx, y: e.bbox.y * sy, width: e.bbox.width * sx, height: e.bbox.height * sy), inView: e.inView) }
        let webElements = try AgentWebObservation.pageTextElement(page.pageText,
            screenshotWidth: Double(dimensions.width), screenshotHeight: Double(dimensions.height),
            bridgeElements: elements)
        let focus = page.focus.map { AgentFocus(id: $0.id, role: $0.role, name: $0.name,
            valuePrefix: $0.value_prefix, selection: AgentSelection(start: $0.selection.first ?? 0, end: $0.selection.dropFirst().first ?? 0)) }
        let observation = AgentObservation(task: frame.observation.task, surface: .web(url: page.url, title: page.title),
            screenshot: frame.observation.screenshot, elements: tokenBoundElements(webElements, focusID: page.focus?.id),
            focus: focus, history: frame.observation.history, budget: frame.observation.budget)
        return AgentFrame(observation: observation, scope: frame.scope, authorityDigest: page.authorityDigest)
    }
    private static func pngDimensions(_ data: Data) -> (width: Double, height: Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (1, 1) }
        return (Double(image.width), Double(image.height))
    }
    private static func tokenBoundElements(_ elements: [AgentElement], focusID: Int?) -> [AgentElement] {
        let byteLimit = 48 * 1024
        var kept: [AgentElement] = [], bytes = 0
        for element in elements {
            let cost = (try? JSONEncoder().encode(element).count) ?? 0
            if bytes + cost <= byteLimit { kept.append(element); bytes += cost }
        }
        if let focusID, !kept.contains(where: { $0.id == focusID }), let focus = elements.first(where: { $0.id == focusID }) { kept.append(focus) }
        return kept
    }
    private static func requireSameFocus(_ expected: AgentFocus?, _ fresh: PageSnapshot.Focus?, elements: [AgentElement]) throws {
        guard let expected, let fresh, expected.id == fresh.id, expected.role == fresh.role, expected.name == fresh.name else {
            throw AgentEnvironmentError.targetChanged
        }
        guard let focused = elements.first(where: { $0.id == fresh.id }) else { throw AgentEnvironmentError.targetGone }
        try AgentWebObservation.requireSafeTarget(focused)
    }
    private static func operation(for action: AgentAction) throws -> SafariBridgeOperation {
        switch action { case .click: .click; case .type: .type; case .key: .key; case .scroll: .scroll; case .select: .select; case .drag: .drag
        default: throw AgentEnvironmentError.unsupportedAction }
    }
    private static func targetPayload(_ target: AgentTarget, targets: [AgentElement], screenshot: String, pointIndex: Int = 0) throws -> (id: Int, expected: [String: Any], point: [Double]?) {
        switch target {
        case let .element(id): guard let item = targets.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }; return (id, expected(item), nil)
        case let .point(x, y):
            guard targets.indices.contains(pointIndex) else { throw AgentEnvironmentError.targetGone }
            let image = pngDimensions(Data(base64Encoded: screenshot) ?? Data())
            let item = targets[pointIndex]
            return (item.id, expected(item), [x / max(1, image.width), y / max(1, image.height)])
        }
    }
    private static func expected(_ element: AgentElement) -> [String: Any] {
        ["role": element.role, "name": element.name]
    }
    private static func payload(for action: AgentAction, targets: [AgentElement], focus: PageSnapshot.Focus?, screenshot: String,
                                expectedAuthorityDigest: String) throws -> [String: Any] {
        switch action {
        case let .click(target, button, count):
            let info = try targetPayload(target, targets: targets, screenshot: screenshot)
            return ["id": info.id, "point": info.point as Any? ?? NSNull(), "expected": info.expected, "expectedAuthorityDigest": expectedAuthorityDigest,
                    "button": button?.rawValue as Any? ?? NSNull(), "count": count ?? 1]
        case let .type(target, text, mode):
            var payload: [String: Any] = ["text": text, "mode": mode.rawValue, "expectedAuthorityDigest": expectedAuthorityDigest]
            if let target { let info = try targetPayload(target, targets: targets, screenshot: screenshot); payload["id"] = info.id; payload["expected"] = info.expected }
            else { guard let focus else { throw AgentEnvironmentError.targetGone }; payload["id"] = focus.id; payload["expected"] = ["role": focus.role, "name": focus.name]; payload["focus"] = true }
            return payload
        case let .key(chord):
            guard let focus else { throw AgentEnvironmentError.targetGone }
            return ["chord": chord, "id": focus.id, "expected": ["role": focus.role, "name": focus.name],
                    "focus": true, "expectedAuthorityDigest": expectedAuthorityDigest]
        case let .scroll(target, direction, amount):
            var p: [String: Any] = ["direction": direction.rawValue, "amount": amount, "expectedAuthorityDigest": expectedAuthorityDigest]
            if let target { let info = try targetPayload(target, targets: targets, screenshot: screenshot); p["id"] = info.id; p["expected"] = info.expected; p["point"] = info.point as Any? ?? NSNull() }
            return p
        case let .select(target, option): let info = try targetPayload(target, targets: targets, screenshot: screenshot); return ["id": info.id, "expected": info.expected, "option": option, "expectedAuthorityDigest": expectedAuthorityDigest]
        case let .drag(from, to):
            let a = try targetPayload(from, targets: targets, screenshot: screenshot, pointIndex: 0), b = try targetPayload(to, targets: targets, screenshot: screenshot, pointIndex: 1)
            return ["fromId": a.id, "toId": b.id, "fromPoint": a.point as Any? ?? NSNull(), "toPoint": b.point as Any? ?? NSNull(),
                    "fromExpected": a.expected, "toExpected": b.expected, "expectedAuthorityDigest": expectedAuthorityDigest]
        default: throw AgentEnvironmentError.unsupportedAction
        }
    }
}

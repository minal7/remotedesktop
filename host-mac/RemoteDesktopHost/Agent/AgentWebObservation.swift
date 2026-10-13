import Foundation

struct AgentWebTargetPair {
    let target: AgentTarget
    let expected: AgentElement?
}

enum AgentWebObservation {
    static let pageTextElementID = 0
    static let maximumPageTextCharacters = 4096

    static func pageTextElement(_ pageText: String, screenshotWidth: Double, screenshotHeight: Double,
                                bridgeElements: [AgentElement]) throws -> [AgentElement] {
        guard screenshotWidth.isFinite, screenshotHeight.isFinite, screenshotWidth > 0, screenshotHeight > 0,
              validBridgeElementIDs(bridgeElements) else {
            throw AgentEnvironmentError.unavailable("Safari returned invalid page element identities or dimensions.")
        }
        let text = String(pageText.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maximumPageTextCharacters))
        guard !text.isEmpty else { return bridgeElements }
        let pageTextElement = AgentElement(id: pageTextElementID, role: "page_text", name: text, value: nil,
            state: ["visible", "read_only"],
            bbox: AgentBoundingBox(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight), inView: true)
        return [pageTextElement] + bridgeElements
    }

    static func validBridgeElementIDs(_ elements: [AgentElement]) -> Bool {
        elements.allSatisfy({ $0.id > pageTextElementID }) && Set(elements.map(\.id)).count == elements.count
    }

    static func targetPairs(for action: AgentAction, in elements: [AgentElement]) throws -> [AgentWebTargetPair] {
        func pair(_ target: AgentTarget) throws -> AgentWebTargetPair {
            switch target {
            case let .element(id):
                guard id != pageTextElementID, let expected = elements.first(where: { $0.id == id }) else {
                    throw AgentEnvironmentError.targetGone
                }
                return AgentWebTargetPair(target: target, expected: expected)
            case .point:
                return AgentWebTargetPair(target: target, expected: nil)
            }
        }
        switch action {
        case let .click(target, _, _), let .type(target?, _, _), let .scroll(target?, _, _),
             let .select(target, _), let .setFiles(target, _):
            return [try pair(target)]
        case let .drag(from, to): return [try pair(from), try pair(to)]
        default: return []
        }
    }

    static func resolveTargets(_ pairs: [AgentWebTargetPair], currentElements: [AgentElement],
                               viewport: [Double], screenshotSize: [Double]) throws -> [AgentElement] {
        try validateSize(viewport); try validateSize(screenshotSize)
        return try pairs.map { pair in
            let fresh: AgentElement
            if let expected = pair.expected {
                guard let current = currentElements.first(where: { $0.id == expected.id }) else {
                    throw AgentEnvironmentError.targetGone
                }
                try requireSameTarget(expected, current); fresh = current
            } else if case let .point(x, y) = pair.target {
                guard let hit = element(at: x, y, currentElements: currentElements,
                                        viewport: viewport, screenshotSize: screenshotSize) else {
                    throw AgentEnvironmentError.targetGone
                }
                try requireSafeTarget(hit); fresh = hit
            } else { throw AgentEnvironmentError.targetGone }
            return fresh
        }
    }

    private static func element(at x: Double, _ y: Double, currentElements: [AgentElement],
                                viewport: [Double], screenshotSize: [Double]) -> AgentElement? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < screenshotSize[0], y < screenshotSize[1] else { return nil }
        let px = x * viewport[0] / screenshotSize[0], py = y * viewport[1] / screenshotSize[1]
        return currentElements.first { element in
            guard element.id != pageTextElementID, element.role != "page_text" else { return false }
            return px >= element.bbox.x && py >= element.bbox.y &&
                px <= element.bbox.x + element.bbox.width && py <= element.bbox.y + element.bbox.height
        }
    }

    static func requireSameTarget(_ expected: AgentElement, _ fresh: AgentElement) throws {
        guard expected.role == fresh.role, expected.name == fresh.name else { throw AgentEnvironmentError.targetChanged }
        try requireSafeTarget(fresh)
    }

    static func requireSafeTarget(_ fresh: AgentElement) throws {
        guard fresh.id != pageTextElementID, fresh.role != "page_text", fresh.state.contains("visible") else {
            throw AgentEnvironmentError.targetGone
        }
        guard !fresh.state.contains("covered") else { throw AgentEnvironmentError.targetCovered }
        guard !fresh.state.contains("disabled") else { throw AgentEnvironmentError.disabledTarget }
        guard !AgentContractValidation.isSecureRoleOrState(role: fresh.role, state: fresh.state) else {
            throw AgentEnvironmentError.credentialHandoff
        }
    }

    private static func validateSize(_ size: [Double]) throws {
        guard size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw AgentEnvironmentError.unavailable("Safari returned invalid point-coordinate dimensions.")
        }
    }
}

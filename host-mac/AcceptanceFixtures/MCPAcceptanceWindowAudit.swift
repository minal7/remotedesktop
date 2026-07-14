import CoreGraphics
import Foundation

private struct WindowEvidence: Codable {
    let id: CGWindowID
    let ownerPID: Int
    let ownerName: String
    let windowName: String
    let layer: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let topMenuBarContained: Bool
}

private struct DisplayGeometry: Codable {
    let id: CGDirectDisplayID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct WindowGeometry: Codable {
    let id: CGWindowID
    let layer: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct AuditReport: Codable {
    let matchedWindowCount: Int
    let onDisplayWindowCount: Int
    let onScreenListWindowCount: Int
    let unexpectedVisibleWindowCount: Int
    let unexpectedVisibleOwnerPIDs: [Int]
    let unexpectedVisibleWindows: [WindowEvidence]
    let allowedCaptureStatusIndicators: [WindowEvidence]
    let visibleWindowIDs: [CGWindowID]
    let activeDisplays: [DisplayGeometry]
    let visibleWindowGeometry: [WindowGeometry]
}

private func argumentValues(named name: String) -> [String] {
    var values: [String] = []
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        if argument == name, let value = iterator.next() {
            values.append(value)
        }
    }
    return values
}

private let targetPIDs = Set(argumentValues(named: "--pid").compactMap(Int.init))
private let nameFragments = argumentValues(named: "--name-fragment")
private let targetWindowIDs = Set(
    argumentValues(named: "--window-id").compactMap(UInt32.init))
private let baselineWindowIDs = Set(
    argumentValues(named: "--baseline-window-id").compactMap(UInt32.init))
private let snapshotOnly = CommandLine.arguments.contains("--snapshot-visible-window-ids")
private let allowCaptureStatusIndicator = CommandLine.arguments.contains(
    "--allow-capture-status-indicator")
guard snapshotOnly || !targetPIDs.isEmpty || !nameFragments.isEmpty
        || !targetWindowIDs.isEmpty || !baselineWindowIDs.isEmpty else {
    fputs("window audit requires a target or snapshot mode\n", stderr)
    exit(2)
}

var displayCount: UInt32 = 0
guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
    fputs("could not enumerate displays\n", stderr)
    exit(2)
}
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
    fputs("could not enumerate display bounds\n", stderr)
    exit(2)
}
let displayBounds = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
private let activeDisplays = zip(displayIDs.prefix(Int(displayCount)), displayBounds).map { pair in
    let (displayID, frame) = pair
    return DisplayGeometry(
        id: displayID,
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.width,
        height: frame.height)
}.sorted { $0.id < $1.id }

func windowInfo(_ options: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}

func windowID(_ item: [String: Any]) -> CGWindowID? {
    (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
}

func matches(_ item: [String: Any]) -> Bool {
    let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
    let name = item[kCGWindowName as String] as? String ?? ""
    let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue
    let idMatches = windowID(item).map(targetWindowIDs.contains) ?? false
    return idMatches
        || ((pid.map(targetPIDs.contains) ?? false) && layer == 0 && !name.isEmpty)
        || nameFragments.contains(where: name.contains)
}

func bounds(_ item: [String: Any]) -> CGRect? {
    guard let dictionary = item[kCGWindowBounds as String] else {
        return nil
    }
    return CGRect(dictionaryRepresentation: dictionary as! CFDictionary)
}

func isContainedInActiveDisplayMenuBar(_ frame: CGRect) -> Bool {
    displayBounds.contains { display in
        let menuBarStrip = CGRect(
            x: display.minX,
            y: display.minY,
            width: display.width,
            height: 32)
        return menuBarStrip.contains(frame)
    }
}

let allMatches = windowInfo([.optionAll, .excludeDesktopElements]).filter(matches)
let visibleWindows = windowInfo([.optionOnScreenOnly, .excludeDesktopElements])
    .filter { item in
        guard let frame = bounds(item), frame.width > 0, frame.height > 0 else {
            return false
        }
        return displayBounds.contains(where: { $0.intersects(frame) })
    }
let visibleWindowIDs = visibleWindows.compactMap(windowID).sorted()
private let visibleWindowGeometry = visibleWindows.compactMap { item -> WindowGeometry? in
    guard let id = windowID(item), let frame = bounds(item) else {
        return nil
    }
    return WindowGeometry(
        id: id,
        layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.width,
        height: frame.height)
}.sorted { $0.id < $1.id }
let onScreenIDs = Set(visibleWindows.filter(matches).compactMap(windowID))
let onDisplay = allMatches.filter { item in
    guard let frame = bounds(item), frame.width > 0, frame.height > 0 else {
        return false
    }
    return displayBounds.contains(where: { $0.intersects(frame) })
}
let onScreenMatches = allMatches.filter {
    guard windowID($0).map(onScreenIDs.contains) ?? false,
          let frame = bounds($0) else {
        return false
    }
    // WindowServer's optionOnScreenOnly includes ordered windows that are
    // wholly outside every display. Intersect with active display bounds so
    // this audit answers the user-visible question rather than order state.
    return displayBounds.contains(where: { $0.intersects(frame) })
}
let newVisibleWindowIDs = baselineWindowIDs.isEmpty
    ? []
    : visibleWindowIDs.filter { !baselineWindowIDs.contains($0) }
let newVisibleIDSet = Set(newVisibleWindowIDs)
private let eligibleCaptureStatusIndicators = visibleWindows.filter { item in
    guard allowCaptureStatusIndicator,
          let id = windowID(item), newVisibleIDSet.contains(id),
          item[kCGWindowOwnerName as String] as? String == "Window Server",
          item[kCGWindowName as String] as? String == "StatusIndicator",
          (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 2_147_483_630,
          let frame = bounds(item),
          frame.width > 0, frame.height > 0,
          frame.width <= 32, frame.height <= 32 else {
        return false
    }
    return isContainedInActiveDisplayMenuBar(frame)
}.sorted { (windowID($0) ?? 0) < (windowID($1) ?? 0) }
let allowedCaptureStatusIndicatorIDs = Set(
    eligibleCaptureStatusIndicators.prefix(2).compactMap(windowID))
let unexpectedVisibleWindowIDs = newVisibleWindowIDs.filter {
    !allowedCaptureStatusIndicatorIDs.contains($0)
}
let unexpectedVisibleIDSet = Set(unexpectedVisibleWindowIDs)
let unexpectedVisibleOwnerPIDs = Set(visibleWindows.compactMap { item -> Int? in
    guard windowID(item).map(unexpectedVisibleIDSet.contains) ?? false else {
        return nil
    }
    return (item[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
}).sorted()
private let unexpectedVisibleWindows = visibleWindows.compactMap { item -> WindowEvidence? in
    guard let id = windowID(item), unexpectedVisibleIDSet.contains(id),
          let frame = bounds(item) else {
        return nil
    }
    return WindowEvidence(
        id: id,
        ownerPID: (item[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1,
        ownerName: item[kCGWindowOwnerName as String] as? String ?? "",
        windowName: (
            item[kCGWindowOwnerName as String] as? String == "Window Server"
                ? item[kCGWindowName as String] as? String ?? ""
                : "<redacted>"),
        layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.width,
        height: frame.height,
        topMenuBarContained: isContainedInActiveDisplayMenuBar(frame))
}.sorted { $0.id < $1.id }
private let allowedCaptureStatusIndicators = visibleWindows.compactMap {
    item -> WindowEvidence? in
    guard let id = windowID(item), allowedCaptureStatusIndicatorIDs.contains(id),
          let frame = bounds(item) else {
        return nil
    }
    return WindowEvidence(
        id: id,
        ownerPID: (item[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1,
        ownerName: item[kCGWindowOwnerName as String] as? String ?? "",
        windowName: item[kCGWindowName as String] as? String ?? "",
        layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.width,
        height: frame.height,
        topMenuBarContained: isContainedInActiveDisplayMenuBar(frame))
}.sorted { $0.id < $1.id }
private let report = AuditReport(
    matchedWindowCount: allMatches.count,
    onDisplayWindowCount: onDisplay.count,
    onScreenListWindowCount: onScreenMatches.count,
    unexpectedVisibleWindowCount: unexpectedVisibleWindowIDs.count,
    unexpectedVisibleOwnerPIDs: unexpectedVisibleOwnerPIDs,
    unexpectedVisibleWindows: unexpectedVisibleWindows,
    allowedCaptureStatusIndicators: allowedCaptureStatusIndicators,
    visibleWindowIDs: visibleWindowIDs,
    activeDisplays: activeDisplays,
    visibleWindowGeometry: visibleWindowGeometry)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
FileHandle.standardOutput.write(Data("\n".utf8))
exit(
    onDisplay.isEmpty && onScreenMatches.isEmpty
        && unexpectedVisibleWindowIDs.isEmpty ? 0 : 3)

#!/usr/bin/env swift

import AppKit
import Foundation

private enum IconAppearance: String, CaseIterable {
    case light
    case dark
    case tinted

    static let logoAppearances: [IconAppearance] = [.light, .dark]

    var filenameStem: String {
        switch self {
        case .light: return "AppIcon"
        case .dark: return "AppIconDark"
        case .tinted: return "AppIconTinted"
        }
    }

    var appLogoStem: String {
        switch self {
        case .light: return "AppLogo"
        case .dark: return "AppLogoDark"
        case .tinted: return "AppLogoTinted"
        }
    }

    var appearances: [[String: String]]? {
        switch self {
        case .light:
            return nil
        case .dark:
            return [["appearance": "luminosity", "value": "dark"]]
        case .tinted:
            return [["appearance": "luminosity", "value": "tinted"]]
        }
    }

    var topColor: NSColor {
        switch self {
        case .light:
            return NSColor(hex: 0xF6FBFF)
        case .dark:
            return NSColor(hex: 0x121721)
        case .tinted:
            return NSColor(hex: 0xF8F8F8)
        }
    }

    var bottomColor: NSColor {
        switch self {
        case .light:
            return NSColor(hex: 0xDCEBFF)
        case .dark:
            return NSColor(hex: 0x202A3A)
        case .tinted:
            return NSColor(hex: 0xDADADA)
        }
    }

    var bezelColor: NSColor {
        switch self {
        case .light:
            return NSColor(hex: 0x262A32)
        case .dark:
            return NSColor(hex: 0xEEF4FF)
        case .tinted:
            return NSColor(hex: 0x242424)
        }
    }

    var standColor: NSColor {
        switch self {
        case .light:
            return NSColor(hex: 0xB4B4BE)
        case .dark:
            return NSColor(hex: 0xCCD6E5)
        case .tinted:
            return NSColor(hex: 0xB8B8B8)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }

    var deviceCGColor: CGColor {
        usingColorSpace(.deviceRGB)?.cgColor ?? cgColor
    }
}

private func renderIcon(size: Int, appearance: IconAppearance, transparent: Bool) throws -> Data {
    let alphaInfo = transparent
        ? CGImageAlphaInfo.premultipliedLast.rawValue
        : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alphaInfo
    ) else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not create bitmap for \(size)x\(size)"
        ])
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    if transparent {
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    } else {
        let colors = [appearance.topColor.deviceCGColor, appearance.bottomColor.deviceCGColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(size)),
            end: CGPoint(x: CGFloat(size), y: 0),
            options: []
        )

        let scale = CGFloat(size) / 64.0
        let glowRect = CGRect(x: 11 * scale, y: 10 * scale, width: 42 * scale, height: 34 * scale)
        context.addPath(CGPath(
            roundedRect: glowRect,
            cornerWidth: 12 * scale,
            cornerHeight: 12 * scale,
            transform: nil
        ))
        context.setFillColor(NSColor.white.withAlphaComponent(appearance == .dark ? 0.05 : 0.20).deviceCGColor)
        context.fillPath()
    }

    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        let scale = CGFloat(size) / 64.0
        return CGRect(
            x: x0 * scale,
            y: (64.0 - y1) * scale,
            width: (x1 - x0) * scale,
            height: (y1 - y0) * scale
        )
    }

    func fillRounded(_ cgRect: CGRect, radius: CGFloat, color: NSColor) {
        let scale = CGFloat(size) / 64.0
        context.addPath(CGPath(
            roundedRect: cgRect,
            cornerWidth: radius * scale,
            cornerHeight: radius * scale,
            transform: nil
        ))
        context.setFillColor(color.deviceCGColor)
        context.fillPath()
    }

    func strokeRounded(_ cgRect: CGRect, radius: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let scale = CGFloat(size) / 64.0
        context.addPath(CGPath(
            roundedRect: cgRect.insetBy(dx: lineWidth * scale / 2, dy: lineWidth * scale / 2),
            cornerWidth: radius * scale,
            cornerHeight: radius * scale,
            transform: nil
        ))
        context.setStrokeColor(color.deviceCGColor)
        context.setLineWidth(lineWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    let scale = CGFloat(size) / 64.0
    let stroke = transparent ? 4.1 : 3.7
    let screenRect = rect(10, 12, 54, 42)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: transparent ? -1.2 * scale : -2.2 * scale),
        blur: transparent ? 1.5 * scale : 5.0 * scale,
        color: NSColor.black.withAlphaComponent(transparent ? 0.18 : 0.22).deviceCGColor
    )
    strokeRounded(screenRect, radius: 7.5, color: appearance.bezelColor, lineWidth: stroke)
    context.restoreGState()

    let standColor = transparent ? appearance.bezelColor : appearance.standColor
    fillRounded(rect(30, 42, 34, 50), radius: 1.9, color: standColor)
    fillRounded(rect(22, 50, 42, 54), radius: 2.1, color: standColor)

    guard let cgImage = context.makeImage() else {
        throw NSError(domain: "IconGeneration", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not create image for \(size)x\(size)"
        ])
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not encode PNG for \(size)x\(size)"
        ])
    }
    return data
}

private func writePNG(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func reset(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func rootContents() -> [String: Any] {
    ["info": ["author": "xcode", "version": 1]]
}

private func iconEntry(
    filename: String,
    idiom: String,
    size: String,
    scale: String? = nil,
    platform: String? = nil,
    appearances: [[String: String]]? = nil
) -> [String: Any] {
    var entry: [String: Any] = [
        "filename": filename,
        "idiom": idiom,
        "size": size
    ]
    if let scale {
        entry["scale"] = scale
    }
    if let platform {
        entry["platform"] = platform
    }
    if let appearances {
        entry["appearances"] = appearances
    }
    return entry
}

private func imageEntry(
    filename: String,
    scale: String,
    appearances: [[String: String]]? = nil
) -> [String: Any] {
    var entry: [String: Any] = [
        "filename": filename,
        "idiom": "universal",
        "scale": scale
    ]
    if let appearances {
        entry["appearances"] = appearances
    }
    return entry
}

private func colorEntry(hex: UInt32, appearances: [[String: String]]? = nil) -> [String: Any] {
    func component(_ shift: UInt32) -> String {
        String(format: "%.3f", Double((hex >> shift) & 0xFF) / 255.0)
    }

    var entry: [String: Any] = [
        "idiom": "universal",
        "color": [
            "color-space": "srgb",
            "components": [
                "alpha": "1.000",
                "blue": component(0),
                "green": component(8),
                "red": component(16)
            ]
        ]
    ]
    if let appearances {
        entry["appearances"] = appearances
    }
    return entry
}

private func generateAppLogo(in catalog: URL) throws {
    let logoSet = catalog.appendingPathComponent("AppLogo.imageset")
    try reset(logoSet)

    var entries: [[String: Any]] = []
    let scales: [(String, Int)] = [("1x", 128), ("2x", 256), ("3x", 384)]

    for appearance in IconAppearance.logoAppearances {
        for (scale, pixels) in scales {
            let suffix = scale == "1x" ? "" : "@\(scale)"
            let filename = "\(appearance.appLogoStem)\(suffix).png"
            try writePNG(
                try renderIcon(size: pixels, appearance: appearance, transparent: true),
                to: logoSet.appendingPathComponent(filename)
            )
            entries.append(imageEntry(
                filename: filename,
                scale: scale,
                appearances: appearance.appearances
            ))
        }
    }

    try writeJSON([
        "images": entries,
        "info": ["author": "xcode", "version": 1]
    ], to: logoSet.appendingPathComponent("Contents.json"))
}

private func generateAccentColor(in catalog: URL) throws {
    let colorSet = catalog.appendingPathComponent("AccentColor.colorset")
    try reset(colorSet)
    try writeJSON([
        "colors": [
            colorEntry(hex: 0x3A84FF),
            colorEntry(hex: 0x5FA8FF, appearances: [["appearance": "luminosity", "value": "dark"]])
        ],
        "info": ["author": "xcode", "version": 1]
    ], to: colorSet.appendingPathComponent("Contents.json"))
}

private func generateIOSCatalog(at catalog: URL) throws {
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    try writeJSON(rootContents(), to: catalog.appendingPathComponent("Contents.json"))
    try generateAccentColor(in: catalog)
    try generateAppLogo(in: catalog)

    let appIconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try reset(appIconSet)

    var entries: [[String: Any]] = []
    for appearance in IconAppearance.allCases {
        let filename = "\(appearance.filenameStem).png"
        try writePNG(
            try renderIcon(size: 1024, appearance: appearance, transparent: false),
            to: appIconSet.appendingPathComponent(filename)
        )
        entries.append(iconEntry(
            filename: filename,
            idiom: "universal",
            size: "1024x1024",
            platform: "ios",
            appearances: appearance.appearances
        ))
    }

    try writeJSON([
        "images": entries,
        "info": ["author": "xcode", "version": 1]
    ], to: appIconSet.appendingPathComponent("Contents.json"))
}

private func generateMacCatalog(at catalog: URL) throws {
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    try writeJSON(rootContents(), to: catalog.appendingPathComponent("Contents.json"))
    try generateAccentColor(in: catalog)
    try generateAppLogo(in: catalog)

    let appIconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try reset(appIconSet)

    let slots: [(size: String, scale: String, pixels: Int, suffix: String)] = [
        ("16x16", "1x", 16, "16"),
        ("16x16", "2x", 32, "16@2x"),
        ("32x32", "1x", 32, "32"),
        ("32x32", "2x", 64, "32@2x"),
        ("128x128", "1x", 128, "128"),
        ("128x128", "2x", 256, "128@2x"),
        ("256x256", "1x", 256, "256"),
        ("256x256", "2x", 512, "256@2x"),
        ("512x512", "1x", 512, "512"),
        ("512x512", "2x", 1024, "512@2x")
    ]

    var entries: [[String: Any]] = []
    for slot in slots {
        let filename = "AppIcon-\(slot.suffix).png"
        try writePNG(
            try renderIcon(size: slot.pixels, appearance: .light, transparent: false),
            to: appIconSet.appendingPathComponent(filename)
        )
        entries.append(iconEntry(
            filename: filename,
            idiom: "mac",
            size: slot.size,
            scale: slot.scale
        ))
    }

    try writeJSON([
        "images": entries,
        "info": ["author": "xcode", "version": 1]
    ], to: appIconSet.appendingPathComponent("Contents.json"))
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try generateIOSCatalog(at: root.appendingPathComponent("ios/RemoteDesktop/Assets.xcassets"))
try generateMacCatalog(at: root.appendingPathComponent("host-mac/RemoteDesktopHost/Assets.xcassets"))
print("Generated iOS and macOS icon asset catalogs.")

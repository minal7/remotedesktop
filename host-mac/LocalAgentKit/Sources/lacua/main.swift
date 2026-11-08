import AppKit
import Foundation
import LocalAgentKit

/// Development driver: runs one task on this Mac with a local model.
/// lacua run "goal" --server PATH --model PATH [--mmproj PATH] [--trace DIR] [--ctx N] [--no-vision] [--auto-approve]
/// lacua scene     prints what the harness sees right now, with no model involved

setvbuf(stdout, nil, _IOLBF, 0)

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

let command = CommandLine.arguments.dropFirst().first ?? ""

if command == "scene" {
    Task {
        let start = Date()
        let scene = await SceneBuilder().build()
        let estimator = TokenEstimator()
        let rendered = SceneRenderer.render(scene, tokens: Int(option("--tokens") ?? "") ?? 1_700, estimator: estimator,
                                            keywords: SceneRenderer.keywords(from: option("--keywords") ?? ""))
        print(rendered.text)
        print("---\nelements \(scene.elements.count) shown \(rendered.shownIDs.count) ocr \(scene.usedOCR) took \(String(format: "%.2f", Date().timeIntervalSince(start)))s est_tokens \(estimator.estimate(rendered.text))")
        exit(0)
    }
    RunLoop.main.run()
}

// Offline check of a computer-use model on a saved screenshot. Nothing touches the screen.
if command == "probe" {
    guard let server = option("--server"), let model = option("--model"), let projector = option("--mmproj"),
          let imagePath = option("--image"), let goal = option("--goal"), let dialect = CUADialect.named(option("--dialect") ?? ""),
          let image = FileManager.default.contents(atPath: imagePath) else { print("probe needs --server --model --mmproj --image --goal --dialect"); exit(2) }
    var config = LlamaServer.Configuration(serverBinary: URL(fileURLWithPath: server), modelFile: URL(fileURLWithPath: model),
                                           projectorFile: URL(fileURLWithPath: projector), contextTokens: Int(option("--ctx") ?? "") ?? 12_288)
    config.extraArguments = dialect.serverArguments
    config.templateOptions = dialect.templateOptions
    let client = LlamaServer(configuration: config)
    Task {
        let load = Date()
        do {
            try await client.start()
            print(String(format: "loaded in %.1fs", Date().timeIntervalSince(load)))
            for run in 1...2 {
                let request = ModelRequest(messages: [.init(role: .system, text: dialect.systemPrompt),
                                                      .init(role: .user, text: dialect.instructionText(goal, []), imageJPEG: image)],
                                           schema: nil, maxTokens: dialect.maxTokens, temperature: dialect.temperature, timeout: 300)
                let reply = try await client.complete(request)
                print(String(format: "--- run %d: %.1fs, %d prompt tokens (%d cached), %d output", run, reply.seconds, reply.promptTokens, reply.cachedTokens, reply.outputTokens))
                print(reply.text)
                print("PARSED:", dialect.parse(reply.text, pointer: nil))
            }
        } catch { print("FAILED:", error) }
        print(String(format: "footprint %.2f GB", Double(client.residentBytes ?? 0) / 1_073_741_824))
        client.stop()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }
    RunLoop.main.run()
}

guard command == "run", CommandLine.arguments.count > 2 else {
    print("usage: lacua run \"goal\" --server PATH --model PATH [--mmproj PATH] [--trace DIR] [--ctx N] [--no-vision] [--auto-approve] [--deny-approvals] [--answer TEXT] [--max-steps N]")
    exit(2)
}

let goal = CommandLine.arguments[2]
guard let serverPath = option("--server"), let modelPath = option("--model") else {
    print("--server and --model are required")
    exit(2)
}
var serverConfig = LlamaServer.Configuration(
    serverBinary: URL(fileURLWithPath: serverPath), modelFile: URL(fileURLWithPath: modelPath),
    projectorFile: option("--mmproj").map { URL(fileURLWithPath: $0) }, contextTokens: Int(option("--ctx") ?? "") ?? 8_192)
// With a computer-use model the main model plans and checks, and this one acts.
// Run alone with --cua-only: the same model does everything.
var worker: CUAWorker?
var cuaServer: LlamaServer?
if let name = option("--dialect") {
    guard let dialect = CUADialect.named(name) else { print("unknown dialect \(name)"); exit(2) }
    var config = LlamaServer.Configuration(serverBinary: URL(fileURLWithPath: serverPath),
                                           modelFile: URL(fileURLWithPath: option("--cua-model") ?? modelPath),
                                           projectorFile: (option("--cua-mmproj") ?? option("--mmproj")).map { URL(fileURLWithPath: $0) },
                                           contextTokens: Int(option("--cua-ctx") ?? "") ?? 12_288)
    config.extraArguments = dialect.serverArguments
    config.templateOptions = dialect.templateOptions
    let client = LlamaServer(configuration: config)
    cuaServer = client
    let made = CUAWorker(model: client, dialect: dialect)
    if let frame = option("--cua-frame") { made.frameOverride = CUADialect.Frame(rawValue: frame) }
    if !flag("--cua-slide") { made.contextTokens = config.contextTokens }
    if let shots = option("--cua-shots").flatMap(Int.init) { made.dialect.screenshotsKept = shots }
    worker = made
}
serverConfig.extraArguments += flag("--cua-only") ? (worker?.dialect.serverArguments ?? []) : []
// A planner answers in a strict JSON shape, with no thinking aloud first.
if worker != nil, !flag("--cua-only") { serverConfig.templateOptions = ["enable_thinking": false] }
let server = LlamaServer(configuration: serverConfig)

var configuration = HarnessConfiguration()
configuration.supportsVision = option("--mmproj") != nil && !flag("--no-vision")
configuration.budget = ContextBudget(contextTokens: serverConfig.contextTokens)
if let steps = option("--max-steps").flatMap(Int.init) { configuration.maximumSteps = steps }
if let jobs = option("--max-jobs").flatMap(Int.init) { configuration.maximumJobs = jobs }
if let steps = option("--job-steps").flatMap(Int.init) { configuration.workerSteps = steps }
if let tokens = option("--planner-screen").flatMap(Int.init) { configuration.plannerScreenTokens = tokens }
if let tokens = option("--planner-log").flatMap(Int.init) { configuration.plannerLogTokens = tokens }
if flag("--no-compaction") { configuration.plannerCompaction = false }
if flag("--worker-first") { configuration.workerFirst = true }
if flag("--no-verify") { configuration.verifyCompletion = false }
if flag("--no-plan") { configuration.planFirst = false }
configuration.orchestrated = worker != nil && !flag("--cua-only")

// Hand the machine back the moment a real person touches it.
let physicalStop = PhysicalInputWatcher()
// Test runs act only in their own apps; anything else in front belongs to the person.
let keepToTestApps = flag("--keep-off-own-browsers")
let throwawayBrowser = option("--chrome-pid").flatMap(Int32.init)
@Sendable func isTestApp(_ app: NSRunningApplication?) -> Bool {
    guard let app else { return false }
    let id = app.bundleIdentifier ?? ""
    return app.processIdentifier == throwawayBrowser || id.hasPrefix("com.threadmark.localagent.fixture.")
}
@Sendable func testFence() -> String? {
    guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
    if isTestApp(front) { return nil }
    return "this run keeps to its own apps, and \(front.localizedName ?? "another app") is in front"
}
/// The system panels a test app's own file and print dialogs are drawn by.
let panelOwners: Set<String> = ["Open and Save Panel Service", "QuickLookUIService", "com.apple.appkit.xpc.openAndSavePanelService", "PrintUI", "Print Center"]
/// Where the Dock's bar of icons is on screen, or nil if that can't be read.
@Sendable func dockBar(pid: pid_t) -> CGRect? {
    let dock = AXUIElementCreateApplication(pid)
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &children) == .success,
          let list = (children as? [AXUIElement])?.first else { return nil }
    var position: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
          AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}
/// Whose window is under a point, from the top. Anything unrecognised is refused.
@Sendable func testPointFence(_ point: CGPoint) -> String? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return "this run couldn't tell what is at that spot"
    }
    for window in windows {
        guard let box = window[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: box as CFDictionary), frame.contains(point),
              (window[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { continue }
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
        // The Dock sometimes keeps a clear window over the whole screen. Only its bar counts as the Dock.
        if owner == "Dock", TestRunFence.dockPassesThrough(window: frame, display: CGDisplayBounds(CGMainDisplayID()), bar: dockBar(pid: pid), point: point) { continue }
        if isTestApp(NSRunningApplication(processIdentifier: pid)) || panelOwners.contains(owner) { return nil }
        // The menu bar: the front app's own menus, but not the Apple menu or the status items.
        if owner == "Window Server" || owner == "SystemUIServer" || owner == "Control Center" {
            let strip = ScreenCapturer.appMenuStrip(display: CGDisplayBounds(CGMainDisplayID()), menuBarHeight: frame.height)
            if frame.minY == CGDisplayBounds(CGMainDisplayID()).minY, strip.contains(point) { return nil }
        }
        return "this run keeps to its own apps, and that spot belongs to \(owner.isEmpty ? "another app" : owner)"
    }
    return "this run keeps to its own apps, and that spot is the desktop"
}
let fence: (@Sendable () -> String?)? = keepToTestApps ? testFence : nil
let pointFence: (@Sendable (CGPoint) -> String?)? = keepToTestApps ? testPointFence : nil
// Anything else that comes forward goes back behind the test app, so the models don't see it.
// That includes the question macOS asks at a test app's first print sheet: nobody here answers
// it, and it is left for the person. Once a person has touched the Mac, the front is theirs.
if keepToTestApps {
    var lastTestApp: NSRunningApplication?
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        guard !physicalStop.interrupted, let front = NSWorkspace.shared.frontmostApplication else { return }
        if testFence() == nil { lastTestApp = front }
        else if front.processIdentifier != ProcessInfo.processInfo.processIdentifier, !panelOwners.contains(front.localizedName ?? "") {
            // A test app that opened behind the person's own window has never been in front yet.
            (lastTestApp ?? NSWorkspace.shared.runningApplications.first { isTestApp($0) })?.activate()
        }
    }
}
let actuator = Actuator(input: DirectInputSink(mayAct: { !physicalStop.interrupted }, fence: fence, pointFence: pointFence))
// Test runs keep to a throwaway browser profile, away from the person's own tabs.
if let profile = option("--chrome-profile"), let pid = option("--chrome-pid").flatMap(Int32.init) {
    actuator.urlOpener = { url in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        process.arguments = ["--user-data-dir=\(profile)", url.absoluteString]
        try process.run()
        process.waitUntilExit()
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
// Test runs never bring up the person's own browsers, whatever the model asks for.
if flag("--keep-off-own-browsers") {
    let browsers: Set<String> = ["safari", "chrome", "google chrome", "firefox", "arc", "edge", "microsoft edge", "brave", "brave browser", "opera", "vivaldi"]
    let throwaway = throwawayBrowser
    // Without this a link would open in the person's default browser.
    if throwaway == nil {
        actuator.urlOpener = { _ in throw ActuationError.unavailable("no browser is needed for this task") }
    }
    actuator.appOpener = { name in
        let key = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        if browsers.contains(key) {
            guard let throwaway, let browser = NSRunningApplication(processIdentifier: throwaway) else {
                throw ActuationError.unavailable("no browser is needed for this task")
            }
            browser.activate()
            return "Google Chrome"
        }
        // Only the apps this run started. Nothing else on this Mac comes forward, by any name.
        let testApps = NSWorkspace.shared.runningApplications.filter { isTestApp($0) && $0.processIdentifier != throwaway }
        guard let match = testApps.first(where: { ($0.localizedName ?? "").lowercased() == key }) else {
            let names = testApps.compactMap(\.localizedName)
            throw ActuationError.unavailable("this run has no app called \"\(name)\". Its apps are: \((names + (throwaway == nil ? [] : ["Google Chrome"])).joined(separator: ", "))")
        }
        match.activate()
        return match.localizedName ?? name
    }
}
if keepToTestApps {
    configuration.frontFence = testFence
    configuration.fileRoot = NSHomeDirectory() + "/LocalAgentEval"
    configuration.visibleApps = {
        NSWorkspace.shared.runningApplications.compactMap { isTestApp($0) ? ($0.processIdentifier == throwawayBrowser ? "Google Chrome" : $0.localizedName) : nil }
    }
}
let mainModel: ModelClient = flag("--cua-only") ? (cuaServer ?? server) : server
let harness = AgentHarness(goal: goal, model: mainModel, actuator: actuator, configuration: configuration, worker: worker)
if let trace = option("--trace") { harness.trace = TraceWriter(directory: URL(fileURLWithPath: trace)) }
physicalStop.start { harness.pauseRequested = true }
harness.onStep = { event in
    let line = String(format: "%2d %-9@ %@ | %d tok (%d cached, +%d) %.1fs model %.1fs observe%@", event.step, event.toolName as NSString,
                      event.narration, event.promptTokens, event.cachedTokens, event.outputTokens, event.modelSeconds, event.observeSeconds,
                      event.usedImage ? " [image]" : "")
    print(line)
    print("   \(event.thought)")
}

let started = Date()
Task {
    var answersGiven = 0
    var outcome = await harness.run()
    while true {
        switch outcome {
        case let .needsApproval(request):
            print("APPROVAL: \(request.reason)")
            if flag("--deny-approvals") { outcome = await harness.resume(approval: request.id, approved: false); continue }
            if flag("--auto-approve") { outcome = await harness.resume(approval: request.id, approved: true); continue }
            print("OUTCOME needs_approval")
        case let .needsAnswer(question):
            print("QUESTION: \(question.question) \(question.choices)")
            // A person says yes to "ready to send?", but won't keep saying it to an agent that's stuck.
            if let answer = option("--answer"), answersGiven < 3 {
                answersGiven += 1
                outcome = await harness.resume(answer: answer)
                continue
            }
            print("OUTCOME needs_answer")
        case let .completed(answer, verified): print("OUTCOME completed verified=\(verified): \(answer)")
        case let .failed(reason): print("OUTCOME failed: \(reason)")
        case let .handoff(reason): print("OUTCOME handoff: \(reason)")
        case .paused: print("OUTCOME paused (a person used the mouse or keyboard)")
        case .cancelled: print("OUTCOME cancelled")
        }
        break
    }
    print(String(format: "ELAPSED %.1fs; server footprint %.2f GB", Date().timeIntervalSince(started),
                 Double((server.residentBytes ?? 0) + (cuaServer?.residentBytes ?? 0)) / 1_073_741_824))
    print(String(format: "PEAK main %.2f GB; worker %.2f GB", Double(server.peakBytes ?? 0) / 1_073_741_824, Double(cuaServer?.peakBytes ?? 0) / 1_073_741_824))
    server.stop()
    cuaServer?.stop()
    try? await Task.sleep(for: .milliseconds(300))
    exit(0)
}
RunLoop.main.run()

/// Stops the run when a real person touches the mouse or keyboard. Listens at the
/// HID tap and ignores events carrying our own tag.
final class PhysicalInputWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    private var onInterrupt: (@Sendable () -> Void)?
    var interrupted: Bool { lock.withLock { flagged } }

    func start(onInterrupt: @escaping @Sendable () -> Void) {
        guard !flag("--ignore-person") else { return }
        self.onInterrupt = onInterrupt
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<PhysicalInputWatcher>.fromOpaque(info).takeUnretainedValue()
            if event.getIntegerValueField(.eventSourceUserData) != DirectInputSink.eventTag { watcher.trip() }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("warning: can't watch for physical input")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func trip() {
        let first = lock.withLock { () -> Bool in
            if flagged { return false }
            flagged = true
            return true
        }
        if first { print("A person touched the mouse or keyboard: pausing."); onInterrupt?() }
    }
}

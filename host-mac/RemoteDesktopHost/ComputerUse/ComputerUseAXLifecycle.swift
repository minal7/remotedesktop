import AppKit
import ApplicationServices

/// Notifications supplement fresh AX reads. Registration success does not
/// promise that an application reports every semantic or lifecycle change.
protocol ComputerUseAXLifecycleMonitoring: AnyObject {
    func drain() -> [ComputerUseAXLifecycleEvent]
    func cancel()
}

struct ComputerUseAXLifecycleEvent {
    enum Kind: Equatable { case scopeChanged, elementChanged, valueChanged, destroyed, coverageLost }
    let kind: Kind
    let element: AXUIElement?
}

/// Callback state owns no adapter or observer. It never calls an AX API,
/// including for destruction events whose object can only be compared locally.
final class ComputerUseAXLifecycleInbox: @unchecked Sendable {
    static let maximumEvents = 256
    private let lock = NSLock()
    private var events: [ComputerUseAXLifecycleEvent] = []
    private var lostCoverage = false
    private var closed = false

    func record(_ event: ComputerUseAXLifecycleEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !lostCoverage else { return }
        guard events.count < Self.maximumEvents else {
            // Dropping a destruction event could permit a later AX query on
            // its invalid handle. Overflow stops this observation scope.
            events.removeAll(); lostCoverage = true
            return
        }
        events.append(event)
    }

    func drain() -> [ComputerUseAXLifecycleEvent] {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return [] }
        if lostCoverage { return [.init(kind: .coverageLost, element: nil)] }
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; events.removeAll()
    }
}

/// AX refcon is deliberately nil. A callback looks up a retained inbox by
/// the still-live observer object's identity, never an unowned Swift pointer.
/// Removal closes the inbox, including callbacks already copying its entry.
final class ComputerUseAXLifecycleCallbacks: @unchecked Sendable {
    struct Registration { fileprivate let key: ObjectIdentifier; fileprivate let nonce: UUID }
    private struct Entry { let nonce: UUID; let inbox: ComputerUseAXLifecycleInbox }
    static let shared = ComputerUseAXLifecycleCallbacks()
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(source: AnyObject, inbox: ComputerUseAXLifecycleInbox) -> Registration {
        let registration = Registration(key: ObjectIdentifier(source), nonce: UUID())
        lock.lock(); defer { lock.unlock() }
        entries[registration.key]?.inbox.close()
        entries[registration.key] = Entry(nonce: registration.nonce, inbox: inbox)
        return registration
    }

    func remove(_ registration: Registration) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[registration.key], entry.nonce == registration.nonce else { return }
        entries.removeValue(forKey: registration.key)
        entry.inbox.close()
    }

    func deliver(source: AnyObject, element: AXUIElement, notification: String) {
        guard let kind = ComputerUseAXLifecycleMonitor.kind(for: notification) else { return }
        lock.lock()
        let inbox = entries[ObjectIdentifier(source)]?.inbox
        lock.unlock()
        inbox?.record(.init(kind: kind, element: element))
    }
}

final class ComputerUseAXLifecycleMonitor: ComputerUseAXLifecycleMonitoring {
    /// Kept for readiness/qualification instead of interpreting unsupported
    /// registration as evidence that no change occurred.
    private(set) var registrationResults: [String: AXError] = [:]
    private(set) var creationResult: AXError = .failure
    private let inbox = ComputerUseAXLifecycleInbox()
    private var observer: AXObserver?
    private var callbackRegistration: ComputerUseAXLifecycleCallbacks.Registration?
    private var workspaceCenter: NotificationCenter?
    private var workspaceTokens: [NSObjectProtocol] = []

    static let scopeNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification, kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXSheetCreatedNotification, kAXDrawerCreatedNotification, kAXCreatedNotification,
        kAXLayoutChangedNotification, kAXRowCountChangedNotification,
        kAXRowExpandedNotification, kAXRowCollapsedNotification].map { $0 as String }

    static func kind(for notification: String) -> ComputerUseAXLifecycleEvent.Kind? {
        if scopeNotifications.contains(notification) { return .scopeChanged }
        switch notification {
        case kAXUIElementDestroyedNotification as String: return .destroyed
        case kAXTitleChangedNotification as String: return .elementChanged
        case kAXValueChangedNotification as String: return .valueChanged
        default: return nil
        }
    }

    @MainActor init(application: AXUIElement) {
        var processID: pid_t = 0
        creationResult = AXUIElementGetPid(application, &processID)
        guard creationResult == .success else { return }
        guard processID > 0 else { creationResult = .illegalArgument; return }
        // Workspace activation/deactivation also covers a switch away and
        // back while AX application notifications are unsupported or delayed.
        let center = NSWorkspace.shared.notificationCenter
        workspaceCenter = center
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [inbox] _ in
                inbox.record(.init(kind: .scopeChanged, element: nil))
            })
        }
        let observedProcessID = processID
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [inbox] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier == observedProcessID else { return }
                inbox.record(.init(kind: .scopeChanged, element: nil))
            })
        }
        var created: AXObserver?
        creationResult = AXObserverCreate(processID, { observer, element, notification, _ in
            ComputerUseAXLifecycleCallbacks.shared.deliver(source: observer, element: element, notification: notification as String)
        }, &created)
        guard creationResult == .success else { return }
        guard let created else { creationResult = .failure; return }
        observer = created
        callbackRegistration = ComputerUseAXLifecycleCallbacks.shared.register(source: created, inbox: inbox)
        // Application-root subscriptions receive notifications from that
        // application's elements, including objects not yet discovered.
        _ = AXUIElementSetMessagingTimeout(application, 0.15)
        let names = Self.scopeNotifications + [kAXUIElementDestroyedNotification as String,
            kAXTitleChangedNotification as String, kAXValueChangedNotification as String]
        for name in names {
            registrationResults[name] = AXObserverAddNotification(created, application, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    func drain() -> [ComputerUseAXLifecycleEvent] { inbox.drain() }

    func cancel() {
        // Remove the callback destination before releasing its event source.
        if let callbackRegistration { ComputerUseAXLifecycleCallbacks.shared.remove(callbackRegistration) }
        callbackRegistration = nil
        inbox.close()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        if let workspaceCenter { for token in workspaceTokens { workspaceCenter.removeObserver(token) } }
        workspaceTokens.removeAll(); workspaceCenter = nil
    }

    deinit { cancel() }
}

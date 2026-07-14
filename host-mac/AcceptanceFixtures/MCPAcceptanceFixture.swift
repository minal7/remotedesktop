import AppKit
import Foundation

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        frameRect
    }
}

private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow!
    private var transientWindow: NSWindow?
    private var deliveryNote: NSTextField!
    private var testStatus: NSTextField!
    private var deliveryItem: NSTextField!
    private var deliveryQuantity: NSTextField!
    private var deliveryAddress: NSTextField!
    private var quotedItem: NSTextField!
    private var deliverySubtotal: NSTextField!
    private var deliveryFees: NSTextField!
    private var deliveryTax: NSTextField!
    private var deliveryTotal: NSTextField!
    private var tripStart: NSTextField!
    private var tripDestination: NSTextField!
    private var tripDeparture: NSTextField!
    private var tripRoute: NSTextField!
    private var tripItinerary: NSTextField!
    private var tripArrival: NSTextField!
    private var tripDuration: NSTextField!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        installMainWindow()
        installSignalHandlers()
    }

    /// The fixture stays in the active Space so Accessibility can exercise it,
    /// but every window is positioned beyond the union of all connected
    /// displays before it is ordered. This prevents a one-frame flash while
    /// keeping a real AppKit/AX hierarchy for the pinned helper.
    private func offscreenFrame(size: NSSize, slot: Int) -> NSRect {
        let displays = NSScreen.screens.map(\.frame)
        let minimumX = displays.map(\.minX).min() ?? 0
        let minimumY = displays.map(\.minY).min() ?? 0
        let gap = CGFloat(4_096 + slot * 1_024)
        let frame = NSRect(
            x: minimumX - size.width - gap,
            y: minimumY - size.height - gap,
            width: size.width,
            height: size.height)
        precondition(displays.allSatisfy { !$0.intersects(frame) })
        return frame
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Remote Desktop MCP Test Fixture",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu

        let actionsItem = NSMenuItem(title: "Test Actions", action: nil, keyEquivalent: "")
        let actionsMenu = NSMenu(title: "Test Actions")
        let saveForLater = NSMenuItem(
            title: "Save for Later",
            action: #selector(saveForLater),
            keyEquivalent: "")
        saveForLater.target = self
        actionsMenu.addItem(saveForLater)
        let selectNote = NSMenuItem(
            title: "Select Delivery Note",
            action: #selector(selectDeliveryNote),
            keyEquivalent: "a")
        selectNote.keyEquivalentModifierMask = [.command]
        selectNote.target = self
        actionsMenu.addItem(selectNote)
        actionsItem.submenu = actionsMenu
        mainMenu.addItem(actionsItem)
        NSApp.mainMenu = mainMenu
    }

    private func installMainWindow() {
        let frame = offscreenFrame(size: NSSize(width: 920, height: 720), slot: 0)
        mainWindow = OffscreenWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        mainWindow.title = "Remote Desktop MCP Test Fixture"
        mainWindow.setFrameAutosaveName("")

        let content = NSView(frame: mainWindow.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        mainWindow.contentView = content

        let heading = NSTextField(labelWithString: "Dinner delivery and day-trip tasks")
        heading.frame = NSRect(x: 24, y: 672, width: 620, height: 28)
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        content.addSubview(heading)

        let subheading = NSTextField(
            labelWithString: "Get an itemized dinner quote or organize a simple transit outing.")
        subheading.frame = NSRect(x: 24, y: 646, width: 760, height: 22)
        subheading.textColor = .secondaryLabelColor
        content.addSubview(subheading)

        installDeliveryQuote(in: content)
        installDayTrip(in: content)
        installPreferences(in: content)

        mainWindow.orderFront(nil)
        mainWindow.setFrame(frame, display: false)
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(mainWindow.frame) })
        mainWindow.makeFirstResponder(deliveryNote)
    }

    private func installDeliveryQuote(in content: NSView) {
        let box = NSBox(frame: NSRect(x: 20, y: 286, width: 430, height: 346))
        box.title = "Dinner delivery quote"
        content.addSubview(box)
        guard let panel = box.contentView else { return }

        addLabel("Item", frame: NSRect(x: 16, y: 276, width: 96, height: 22), to: panel)
        deliveryItem = addField(
            title: "Delivery item",
            value: "Choose an item",
            frame: NSRect(x: 116, y: 270, width: 276, height: 28),
            to: panel)
        addLabel("Quantity", frame: NSRect(x: 16, y: 238, width: 96, height: 22), to: panel)
        deliveryQuantity = addField(
            title: "Delivery quantity",
            value: "1",
            frame: NSRect(x: 116, y: 232, width: 80, height: 28),
            to: panel)
        addLabel("Deliver to", frame: NSRect(x: 16, y: 200, width: 96, height: 22), to: panel)
        deliveryAddress = addField(
            title: "Delivery address",
            value: "Home",
            frame: NSRect(x: 116, y: 194, width: 276, height: 28),
            to: panel)

        let quoteButton = NSButton(
            title: "Get delivery quote",
            target: self,
            action: #selector(getDeliveryQuote))
        quoteButton.frame = NSRect(x: 116, y: 154, width: 170, height: 32)
        quoteButton.bezelStyle = .rounded
        quoteButton.setAccessibilityIdentifier("get-delivery-quote")
        panel.addSubview(quoteButton)

        quotedItem = addOutput(
            title: "Quoted item", value: "No item quoted",
            frame: NSRect(x: 16, y: 124, width: 376, height: 20), to: panel)
        deliverySubtotal = addOutput(
            title: "Delivery subtotal", value: "Subtotal —",
            frame: NSRect(x: 16, y: 100, width: 180, height: 20), to: panel)
        deliveryFees = addOutput(
            title: "Delivery fees", value: "Fees —",
            frame: NSRect(x: 212, y: 100, width: 180, height: 20), to: panel)
        deliveryTax = addOutput(
            title: "Delivery tax", value: "Tax —",
            frame: NSRect(x: 16, y: 74, width: 180, height: 20), to: panel)
        deliveryTotal = addOutput(
            title: "Delivery total", value: "Total —",
            frame: NSRect(x: 212, y: 74, width: 180, height: 20), to: panel)
    }

    private func installDayTrip(in content: NSView) {
        let box = NSBox(frame: NSRect(x: 470, y: 286, width: 430, height: 346))
        box.title = "Day-trip transit plan"
        content.addSubview(box)
        guard let panel = box.contentView else { return }

        addLabel("Start", frame: NSRect(x: 16, y: 276, width: 96, height: 22), to: panel)
        tripStart = addField(
            title: "Trip start",
            value: "Starting point",
            frame: NSRect(x: 116, y: 270, width: 276, height: 28),
            to: panel)
        addLabel("Destination", frame: NSRect(x: 16, y: 238, width: 96, height: 22), to: panel)
        tripDestination = addField(
            title: "Trip destination",
            value: "Destination",
            frame: NSRect(x: 116, y: 232, width: 276, height: 28),
            to: panel)
        addLabel("Leave at", frame: NSRect(x: 16, y: 200, width: 96, height: 22), to: panel)
        tripDeparture = addField(
            title: "Trip departure",
            value: "9:00 AM",
            frame: NSRect(x: 116, y: 194, width: 120, height: 28),
            to: panel)

        let planButton = NSButton(
            title: "Plan day trip",
            target: self,
            action: #selector(planDayTrip))
        planButton.frame = NSRect(x: 116, y: 154, width: 150, height: 32)
        planButton.bezelStyle = .rounded
        planButton.setAccessibilityIdentifier("plan-day-trip")
        panel.addSubview(planButton)

        tripRoute = addOutput(
            title: "Trip route", value: "No route planned",
            frame: NSRect(x: 16, y: 124, width: 376, height: 20), to: panel)
        tripItinerary = addOutput(
            title: "Trip itinerary", value: "Transit details —",
            frame: NSRect(x: 16, y: 100, width: 376, height: 20), to: panel)
        tripArrival = addOutput(
            title: "Trip arrival", value: "Arrival —",
            frame: NSRect(x: 16, y: 74, width: 180, height: 20), to: panel)
        tripDuration = addOutput(
            title: "Trip duration", value: "Duration —",
            frame: NSRect(x: 212, y: 74, width: 180, height: 20), to: panel)
    }

    private func installPreferences(in content: NSView) {
        let box = NSBox(frame: NSRect(x: 20, y: 24, width: 880, height: 242))
        box.title = "Delivery preferences"
        content.addSubview(box)
        guard let panel = box.contentView else { return }

        addLabel(
            "Delivery note",
            frame: NSRect(x: 16, y: 160, width: 120, height: 22),
            to: panel)
        deliveryNote = addField(
            title: "Delivery note",
            value: "Ring the doorbell",
            frame: NSRect(x: 140, y: 154, width: 360, height: 30),
            to: panel)
        deliveryNote.identifier = NSUserInterfaceItemIdentifier("delivery-note")

        let utensilsButton = NSButton(
            title: "Add utensils",
            target: self,
            action: #selector(addUtensils))
        utensilsButton.frame = NSRect(x: 520, y: 152, width: 140, height: 34)
        utensilsButton.bezelStyle = .rounded
        utensilsButton.setAccessibilityIdentifier("add-utensils")
        panel.addSubview(utensilsButton)

        let saveButton = NSButton(
            title: "Save delivery note",
            target: self,
            action: #selector(saveDeliveryNote))
        saveButton.frame = NSRect(x: 676, y: 152, width: 170, height: 34)
        saveButton.bezelStyle = .rounded
        saveButton.setAccessibilityIdentifier("save-delivery-note")
        panel.addSubview(saveButton)

        addLabel(
            "Status",
            frame: NSRect(x: 16, y: 116, width: 120, height: 22),
            to: panel)
        testStatus = addOutput(
            title: "Test status",
            value: "Ready",
            frame: NSRect(x: 140, y: 116, width: 360, height: 22),
            to: panel)

        let privacy = NSTextField(
            wrappingLabelWithString: "This local test uses sample prices and routes. It does not place an order, reserve a trip, or contact anyone.")
        privacy.frame = NSRect(x: 16, y: 54, width: 820, height: 42)
        privacy.textColor = .secondaryLabelColor
        panel.addSubview(privacy)
    }

    @discardableResult
    private func addField(
        title: String,
        value: String,
        frame: NSRect,
        to view: NSView
    ) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = value
        field.setAccessibilityTitle(title)
        field.setAccessibilityValue(value)
        view.addSubview(field)
        return field
    }

    @discardableResult
    private func addOutput(
        title: String,
        value: String,
        frame: NSRect,
        to view: NSView
    ) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.frame = frame
        field.setAccessibilityTitle(title)
        view.addSubview(field)
        return field
    }

    private func addLabel(_ value: String, frame: NSRect, to view: NSView) {
        let label = NSTextField(labelWithString: value)
        label.frame = frame
        view.addSubview(label)
    }

    private func installSignalHandlers() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)

        let createWindow = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        createWindow.setEventHandler { [weak self] in self?.createTransientWindow() }
        createWindow.resume()
        signalSources.append(createWindow)

        let changeValue = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        changeValue.setEventHandler { [weak self] in
            guard let self else { return }
            deliveryNote.stringValue = "Leave at front desk"
            setTestStatus("Delivery note updated")
            NSAccessibility.post(element: deliveryNote as Any, notification: .valueChanged)
        }
        changeValue.resume()
        signalSources.append(changeValue)
    }

    private func createTransientWindow() {
        transientWindow?.close()
        let frame = offscreenFrame(size: NSSize(width: 300, height: 160), slot: 1)
        let window = OffscreenWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Trip Reminder"
        let reminder = NSTextField(
            wrappingLabelWithString: "Your sample day trip is ready to review.")
        reminder.frame = NSRect(x: 24, y: 54, width: 252, height: 48)
        window.contentView = reminder
        window.orderFront(nil)
        window.setFrame(frame, display: false)
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        transientWindow = window
    }

    @objc private func getDeliveryQuote() {
        let item = deliveryItem.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = deliveryQuantity.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = deliveryAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.caseInsensitiveCompare("Margherita pizza") == .orderedSame,
              quantity == "2",
              !address.isEmpty else {
            quotedItem.stringValue = "Choose 2 Margherita pizzas for the sample quote"
            deliverySubtotal.stringValue = "Subtotal —"
            deliveryFees.stringValue = "Fees —"
            deliveryTax.stringValue = "Tax —"
            deliveryTotal.stringValue = "Total —"
            setTestStatus("Delivery quote needs complete details")
            return
        }
        quotedItem.stringValue = "2 × Margherita pizza"
        deliverySubtotal.stringValue = "$36.00"
        deliveryFees.stringValue = "$6.69"
        deliveryTax.stringValue = "$3.15"
        deliveryTotal.stringValue = "$45.84"
        setTestStatus("Delivery quote ready for \(address)")
    }

    @objc private func planDayTrip() {
        let start = tripStart.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = tripDestination.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let departure = tripDeparture.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard start.caseInsensitiveCompare("Civic Center") == .orderedSame,
              destination.caseInsensitiveCompare("Ocean Beach") == .orderedSame,
              departure.caseInsensitiveCompare("9:15 AM") == .orderedSame else {
            tripRoute.stringValue = "Enter Civic Center, Ocean Beach, and 9:15 AM"
            tripItinerary.stringValue = "Transit details —"
            tripArrival.stringValue = "Arrival —"
            tripDuration.stringValue = "Duration —"
            setTestStatus("Trip plan needs complete details")
            return
        }
        tripRoute.stringValue = "Civic Center → Ocean Beach"
        tripItinerary.stringValue = "N Judah • 32 min, then walk 5 min"
        tripArrival.stringValue = "9:52 AM"
        tripDuration.stringValue = "37 min"
        setTestStatus("Day trip planned")
    }

    @objc private func addUtensils() { setTestStatus("Utensils added") }
    @objc private func saveDeliveryNote() { setTestStatus("Delivery note saved") }
    @objc private func saveForLater() { setTestStatus("Saved for later") }
    @objc private func selectDeliveryNote() {
        mainWindow.makeFirstResponder(deliveryNote)
        deliveryNote.selectText(nil)
        setTestStatus("Delivery note selected")
    }

    private func setTestStatus(_ value: String) {
        testStatus.stringValue = value
        // mac-control-mcp reads AXValue. NSTextField(labelWithString:)'s
        // default accessibility value can remain its static label even after
        // stringValue changes, so keep the observable value explicit.
        testStatus.setAccessibilityValue(value)
        NSAccessibility.post(element: testStatus as Any, notification: .valueChanged)
    }
}

private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AcceptanceAppDelegate()
application.delegate = delegate
application.run()

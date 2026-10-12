import AppKit
import CoreImage
import CoreText
import XCTest
@testable import RemoteDesktopHost

private enum FixtureRenderingError: Error {
    case couldNotRenderFixture
}

enum OSAtlasAcceptanceFixtureRenderer {
    private static let width = 448
    private static let height = 448

    static let hiddenDisplayBounds = CGRect(
        x: 20_000,
        y: 20_000,
        width: width,
        height: height)
    static let calendarNextWeekTarget = normalizedTopRect(
        x: 276, top: 126, width: 128, height: 42)
    static let summerPicnicFolderTarget = normalizedTopRect(
        x: 60, top: 130, width: 160, height: 160)
    static let groceryPlaceOrderTarget = normalizedTopRect(
        x: 80, top: 320, width: 288, height: 52)
    static let taxReceiptsRowTarget = normalizedTopRect(
        x: 34, top: 174, width: 380, height: 58)
    static let buyGroceriesCardTarget = normalizedTopRect(
        x: 42, top: 178, width: 146, height: 72)
    static let weekendColumnTarget = normalizedTopRect(
        x: 238, top: 112, width: 190, height: 270)

    static func desktopTargetRect(
        for normalizedRect: CGRect,
        displayBounds: CGRect = hiddenDisplayBounds
    ) -> CGRect {
        CGRect(
            x: displayBounds.minX
                + normalizedRect.minX / 1_000 * displayBounds.width,
            y: displayBounds.minY
                + normalizedRect.minY / 1_000 * displayBounds.height,
            width: normalizedRect.width / 1_000 * displayBounds.width,
            height: normalizedRect.height / 1_000 * displayBounds.height)
    }

    private static func normalizedTopRect(
        x: CGFloat,
        top: CGFloat,
        width rectWidth: CGFloat,
        height rectHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: x / CGFloat(width) * 1_000,
            y: top / CGFloat(height) * 1_000,
            width: rectWidth / CGFloat(width) * 1_000,
            height: rectHeight / CGFloat(height) * 1_000)
    }

    enum EverydayOperation: Equatable {
        case calendar
        case photoAlbum
        case finderFile
        case errandBoard
        case focusedNote
        case focusedNoteUpdated
        case feedEarlier
        case feedLater
        case galleryLeft
        case galleryRight
        case notesSuggestion
        case librarySearch
        case librarySearchResults
        case selectedPackingList
        case loadingLocalInventory
        case updatingPrice
        case deliveryPriceReady
        case missingDepartureCity
        case appointmentSummary
        case classSummary
        case finishedChecklist
        case privacyArticleTop
        case privacySection
        case accountSignIn
        case groceryCheckout
        case reportRemoved
        case windowsOnlyApplication
        case calendarNextWeekReached
        case photoAlbumOpened
    }

    static func everydayOperation(
        _ operation: EverydayOperation
    ) throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.965, 0.97, 0.98))

            func header(_ app: String, _ title: String) {
                fill(
                    canvas,
                    rect: rect(x: 0, top: 0, width: 448, height: 58),
                    color: color(0.12, 0.20, 0.34))
                text(
                    canvas,
                    app,
                    x: 20,
                    top: 16,
                    size: 20,
                    color: color(1, 1, 1),
                    bold: true)
                text(
                    canvas,
                    title,
                    x: 20,
                    top: 76,
                    size: 21,
                    color: color(0.10, 0.12, 0.16),
                    bold: true)
            }

            func card(
                x: CGFloat,
                top: CGFloat,
                width: CGFloat,
                height: CGFloat,
                fillColor: CGColor? = nil
            ) {
                fill(
                    canvas,
                    rect: rect(x: x, top: top, width: width, height: height),
                    color: fillColor ?? color(1, 1, 1))
                stroke(
                    canvas,
                    rect: rect(x: x, top: top, width: width, height: height),
                    color: color(0.78, 0.80, 0.84),
                    width: 1)
            }

            switch operation {
            case .calendar:
                header("Family Calendar", "Household schedule")
                card(x: 20, top: 110, width: 408, height: 250)
                text(canvas, "August 10–16", x: 40, top: 134,
                     size: 18, color: color(0.12, 0.14, 0.18), bold: true)
                fill(canvas, rect: rect(x: 276, top: 126, width: 128, height: 42),
                     color: color(0.10, 0.42, 0.88))
                text(canvas, "Next week", x: 298, top: 139,
                     size: 15, color: color(1, 1, 1), bold: true)
                text(canvas, "Mon   Dentist · 3:30 PM", x: 40, top: 202,
                     size: 16, color: color(0.18, 0.20, 0.24))
                text(canvas, "Sat   Neighborhood picnic", x: 40, top: 246,
                     size: 16, color: color(0.18, 0.20, 0.24))

            case .photoAlbum:
                header("Finder", "Desktop")
                card(x: 26, top: 108, width: 396, height: 260,
                     fillColor: color(0.76, 0.88, 0.96))
                fill(canvas, rect: rect(x: 74, top: 152, width: 128, height: 88),
                     color: color(0.22, 0.58, 0.90))
                fill(canvas, rect: rect(x: 88, top: 138, width: 66, height: 26),
                     color: color(0.22, 0.58, 0.90))
                text(canvas, "Summer Picnic", x: 70, top: 258,
                     size: 18, color: color(0.08, 0.10, 0.14), bold: true)
                fill(canvas, rect: rect(x: 270, top: 166, width: 86, height: 70),
                     color: color(1.0, 0.93, 0.75))
                text(canvas, "Invitations", x: 266, top: 258,
                     size: 16, color: color(0.10, 0.12, 0.15), bold: true)
                text(canvas, "Double-click a folder to open it", x: 98, top: 326,
                     size: 15, color: color(0.24, 0.28, 0.34), bold: true)

            case .finderFile:
                header("Finder", "Documents")
                card(x: 22, top: 112, width: 404, height: 230)
                text(canvas, "Name", x: 46, top: 134,
                     size: 13, color: color(0.42, 0.44, 0.48), bold: true)
                fill(canvas, rect: rect(x: 34, top: 174, width: 380, height: 58),
                     color: color(0.78, 0.87, 0.98))
                text(canvas, "PDF", x: 48, top: 192,
                     size: 13, color: color(0.72, 0.10, 0.12), bold: true)
                text(canvas, "Tax receipts.pdf", x: 104, top: 190,
                     size: 18, color: color(0.08, 0.10, 0.14), bold: true)
                text(canvas, "Vacation ideas.txt", x: 104, top: 260,
                     size: 17, color: color(0.18, 0.20, 0.24))

            case .errandBoard:
                header("Errands", "Plan the weekend")
                card(x: 20, top: 112, width: 190, height: 270)
                card(x: 238, top: 112, width: 190, height: 270,
                     fillColor: color(0.94, 0.98, 0.94))
                text(canvas, "TODAY", x: 82, top: 132,
                     size: 15, color: color(0.38, 0.40, 0.44), bold: true)
                text(canvas, "WEEKEND", x: 294, top: 132,
                     size: 15, color: color(0.22, 0.44, 0.25), bold: true)
                fill(canvas, rect: rect(x: 42, top: 178, width: 146, height: 72),
                     color: color(1.0, 0.89, 0.48))
                text(canvas, "Buy groceries", x: 58, top: 202,
                     size: 16, color: color(0.18, 0.15, 0.05), bold: true)
                text(canvas, "Move this card →", x: 58, top: 270,
                     size: 14, color: color(0.42, 0.42, 0.46))

            case .focusedNote:
                header("Notes", "Errands")
                card(x: 24, top: 112, width: 400, height: 278,
                     fillColor: color(1.0, 0.995, 0.90))
                text(canvas, "Weekend errands", x: 46, top: 136,
                     size: 19, color: color(0.12, 0.13, 0.16), bold: true)
                text(canvas, "• Return library books", x: 48, top: 190,
                     size: 17, color: color(0.20, 0.21, 0.24))
                text(canvas, "• Pick up dry cleaning", x: 48, top: 232,
                     size: 17, color: color(0.20, 0.21, 0.24))
                fill(canvas, rect: rect(x: 46, top: 286, width: 330, height: 42),
                     color: color(1, 1, 1))
                stroke(canvas, rect: rect(x: 46, top: 286, width: 330, height: 42),
                       color: color(0.12, 0.46, 0.90), width: 2)
                fill(canvas, rect: rect(x: 64, top: 296, width: 3, height: 24),
                     color: color(0.05, 0.08, 0.12))
                text(canvas, "Focused note editor", x: 78, top: 299,
                     size: 15, color: color(0.48, 0.50, 0.54))

            case .focusedNoteUpdated:
                header("Notes", "Errands")
                card(x: 24, top: 112, width: 400, height: 278,
                     fillColor: color(1.0, 0.995, 0.90))
                text(canvas, "Weekend errands", x: 46, top: 136,
                     size: 19, color: color(0.12, 0.13, 0.16), bold: true)
                text(canvas, "• Return library books", x: 48, top: 190,
                     size: 17, color: color(0.20, 0.21, 0.24))
                text(canvas, "• Pick up dry cleaning", x: 48, top: 232,
                     size: 17, color: color(0.20, 0.21, 0.24))
                text(canvas, "Pick up oat milk at 6 PM", x: 48, top: 286,
                     size: 17, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "REQUESTED LINE ADDED", x: 116, top: 344,
                     size: 14, color: color(0.10, 0.42, 0.20), bold: true)

            case .feedEarlier, .feedLater:
                let earlier = operation == .feedEarlier
                header("Family Activity", earlier ? "See earlier updates" : "See newer updates")
                for index in 0 ..< 3 {
                    let top = CGFloat(112 + index * 86)
                    card(x: 28, top: top, width: 380, height: 68)
                    text(canvas, earlier
                         ? ["Grandma shared a recipe", "Picnic photos", "School reminder"][index]
                         : ["School reminder", "Picnic photos", "Grandma shared a recipe"][index],
                         x: 50, top: top + 20, size: 16,
                         color: color(0.16, 0.18, 0.22), bold: index == 1)
                }
                text(canvas, earlier ? "↑ Earlier items are above" : "↓ Newer items are below",
                     x: 114, top: 390, size: 15,
                     color: color(0.10, 0.42, 0.82), bold: true)

            case .galleryLeft, .galleryRight:
                let left = operation == .galleryLeft
                header("Trip Photos", "Family album")
                for index in 0 ..< 3 {
                    let x = CGFloat((left ? -54 : 24) + index * 166)
                    card(x: x, top: 128, width: 124, height: 180,
                         fillColor: [
                            color(0.75, 0.89, 0.96),
                            color(0.82, 0.92, 0.74),
                            color(0.95, 0.82, 0.70),
                         ][index])
                    text(canvas, "Photo \(index + 4)", x: x + 26, top: 270,
                         size: 14, color: color(0.12, 0.14, 0.18), bold: true)
                }
                fill(canvas, rect: rect(x: 48, top: 344, width: 352, height: 8),
                     color: color(0.82, 0.84, 0.88))
                fill(canvas,
                     rect: rect(x: left ? 274 : 48, top: 344, width: 126, height: 8),
                     color: color(0.34, 0.40, 0.50))
                text(canvas,
                     left ? "Showing later photos; earlier photos are clipped"
                          : "Showing earlier photos; later photos are clipped",
                     x: 66, top: 376, size: 14,
                     color: color(0.30, 0.34, 0.40), bold: true)

            case .notesSuggestion:
                header("Safari", "Weekly meal plan")
                card(x: 38, top: 126, width: 372, height: 210)
                text(canvas, "Monday", x: 68, top: 158,
                     size: 18, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "Vegetable soup and sourdough", x: 68, top: 196,
                     size: 16, color: color(0.26, 0.28, 0.32))
                text(canvas, "Tuesday", x: 68, top: 244,
                     size: 18, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "Tacos with black beans", x: 68, top: 282,
                     size: 16, color: color(0.26, 0.28, 0.32))

            case .librarySearch:
                header("Library", "Find opening hours")
                text(canvas, "Search the library website", x: 42, top: 130,
                     size: 17, color: color(0.18, 0.20, 0.24), bold: true)
                fill(canvas, rect: rect(x: 40, top: 172, width: 368, height: 58),
                     color: color(1, 1, 1))
                stroke(canvas, rect: rect(x: 40, top: 172, width: 368, height: 58),
                       color: color(0.10, 0.42, 0.88), width: 3)
                text(canvas, "library hours|", x: 62, top: 190,
                     size: 19, color: color(0.10, 0.12, 0.16))
                text(canvas, "Query ready — press Return to search", x: 82, top: 260,
                     size: 15, color: color(0.40, 0.42, 0.46))

            case .librarySearchResults:
                header("Library", "Search results")
                text(canvas, "public library hours", x: 48, top: 122,
                     size: 16, color: color(0.38, 0.40, 0.44))
                card(x: 32, top: 158, width: 384, height: 176,
                     fillColor: color(0.94, 0.98, 0.95))
                text(canvas, "Public Library Hours", x: 58, top: 184,
                     size: 21, color: color(0.08, 0.26, 0.50), bold: true)
                text(canvas, "Open today", x: 58, top: 230,
                     size: 18, color: color(0.10, 0.42, 0.20), bold: true)
                text(canvas, "9:00 AM – 6:00 PM", x: 58, top: 270,
                     size: 18, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "SEARCH COMPLETE — RESULTS SHOWN", x: 82, top: 372,
                     size: 14, color: color(0.10, 0.42, 0.20), bold: true)

            case .selectedPackingList:
                header("Notes", "Packing list")
                card(x: 28, top: 116, width: 392, height: 240,
                     fillColor: color(1.0, 0.995, 0.90))
                fill(canvas, rect: rect(x: 50, top: 152, width: 322, height: 116),
                     color: color(0.52, 0.72, 1.0))
                text(canvas, "Passport", x: 66, top: 170,
                     size: 18, color: color(0.04, 0.08, 0.14), bold: true)
                text(canvas, "Phone charger", x: 66, top: 204,
                     size: 18, color: color(0.04, 0.08, 0.14), bold: true)
                text(canvas, "Rain jacket", x: 66, top: 238,
                     size: 18, color: color(0.04, 0.08, 0.14), bold: true)
                text(canvas, "3 lines selected — copy them", x: 92, top: 302,
                     size: 15, color: color(0.38, 0.40, 0.44))

            case .loadingLocalInventory:
                header("Local Browser Workbench", "Generated report")
                card(x: 48, top: 134, width: 352, height: 190)
                text(canvas, "Loading local inventory…", x: 102, top: 198,
                     size: 18, color: color(0.18, 0.42, 0.72), bold: true)
                text(
                    canvas,
                    "Still waiting. No inventory result is present.",
                    x: 58,
                    top: 254,
                    size: 14,
                    color: color(0.46, 0.48, 0.52))

            case .updatingPrice:
                header("Grocery Delivery", "Price check")
                card(x: 48, top: 134, width: 352, height: 190)
                text(canvas, "Weekly groceries", x: 118, top: 168,
                     size: 20, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "Updating latest delivery price…", x: 90, top: 222,
                     size: 17, color: color(0.18, 0.42, 0.72), bold: true)
                text(canvas, "Please wait", x: 170, top: 272,
                     size: 17, color: color(0.46, 0.48, 0.52))

            case .deliveryPriceReady:
                header("Grocery Delivery", "Price check")
                card(x: 48, top: 134, width: 352, height: 210,
                     fillColor: color(0.94, 0.98, 0.95))
                text(canvas, "Weekly groceries", x: 118, top: 168,
                     size: 20, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "LATEST PRICE READY", x: 124, top: 218,
                     size: 15, color: color(0.10, 0.42, 0.20), bold: true)
                text(canvas, "Order total", x: 84, top: 266,
                     size: 18, color: color(0.18, 0.20, 0.24))
                text(canvas, "$24.18", x: 270, top: 258,
                     size: 25, color: color(0.10, 0.42, 0.20), bold: true)
                text(canvas, "Delivery in 25–35 minutes", x: 104, top: 312,
                     size: 16, color: color(0.30, 0.32, 0.36))

            case .missingDepartureCity:
                header("Train Planner", "Weekend visit")
                text(canvas, "TRIP DETAILS", x: 148, top: 146,
                     size: 14, color: color(0.38, 0.40, 0.44), bold: true)
                text(canvas, "Departure city: Not provided", x: 76, top: 194,
                     size: 18, color: color(0.68, 0.12, 0.14), bold: true)
                text(canvas, "Destination: Monterey", x: 76, top: 240,
                     size: 17, color: color(0.16, 0.18, 0.22))
                text(canvas, "Travel day: Saturday", x: 76, top: 282,
                     size: 17, color: color(0.16, 0.18, 0.22))
                text(canvas, "Required information is missing", x: 100, top: 326,
                     size: 16, color: color(0.38, 0.40, 0.44), bold: true)

            case .appointmentSummary:
                header("Health Calendar", "Upcoming appointment")
                text(canvas, "DENTIST APPOINTMENT", x: 108, top: 162,
                     size: 16, color: color(0.16, 0.38, 0.62), bold: true)
                text(canvas, "Tuesday", x: 150, top: 214,
                     size: 26, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "3:30 PM", x: 166, top: 260,
                     size: 23, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "Ready to report", x: 156, top: 304,
                     size: 14, color: color(0.42, 0.44, 0.48))

            case .classSummary:
                header("Community Center", "Class reminder")
                text(canvas, "COMMUNITY YOGA", x: 132, top: 156,
                     size: 18, color: color(0.16, 0.38, 0.62), bold: true)
                text(canvas, "Thursday", x: 158, top: 210,
                     size: 26, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "6:45 PM", x: 170, top: 256,
                     size: 23, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "Studio B", x: 176, top: 302,
                     size: 20, color: color(0.18, 0.34, 0.52), bold: true)
                text(canvas, "Ready to report", x: 156, top: 344,
                     size: 14, color: color(0.42, 0.44, 0.48))

            case .finishedChecklist:
                header("Household Checklist", "Saturday chores")
                let chores = ["✓ Laundry folded", "✓ Recycling out", "✓ Plants watered"]
                for (index, chore) in chores.enumerated() {
                    text(canvas, chore, x: 74, top: CGFloat(154 + index * 52),
                         size: 19, color: color(0.12, 0.42, 0.20), bold: true)
                }
                text(canvas, "ALL ITEMS COMPLETE", x: 126, top: 331,
                     size: 15, color: color(0.10, 0.38, 0.18), bold: true)

            case .privacyArticleTop:
                header("Family Portal Help", "Account guide")
                text(canvas, "Manage your family profile", x: 48, top: 132,
                     size: 22, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "Sharing", x: 48, top: 198,
                     size: 18, color: color(0.18, 0.20, 0.24), bold: true)
                text(canvas, "Notifications", x: 48, top: 250,
                     size: 18, color: color(0.18, 0.20, 0.24), bold: true)
                text(canvas, "More sections are below this viewport", x: 48, top: 332,
                     size: 15, color: color(0.38, 0.40, 0.44))
                text(canvas, "Scroll down to continue", x: 126, top: 378,
                     size: 15, color: color(0.10, 0.42, 0.82), bold: true)

            case .privacySection:
                header("Family Portal Help", "Privacy")
                text(canvas, "Privacy", x: 48, top: 132,
                     size: 28, color: color(0.10, 0.12, 0.16), bold: true)
                card(x: 40, top: 186, width: 368, height: 156,
                     fillColor: color(0.94, 0.97, 1.0))
                text(canvas, "Control who can see family activity", x: 62, top: 214,
                     size: 16, color: color(0.18, 0.20, 0.24), bold: true)
                text(canvas, "Choose how your information is shared", x: 62, top: 258,
                     size: 16, color: color(0.18, 0.20, 0.24))
                text(canvas, "PRIVACY SECTION IS NOW VISIBLE", x: 86, top: 374,
                     size: 14, color: color(0.10, 0.42, 0.20), bold: true)

            case .accountSignIn:
                header("Account", "Sign In")
                text(canvas, "Account Sign In", x: 134, top: 110,
                     size: 23, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "Email or username", x: 74, top: 168,
                     size: 15, color: color(0.30, 0.32, 0.36))
                card(x: 70, top: 194, width: 308, height: 42)
                text(canvas, "Password", x: 74, top: 256,
                     size: 15, color: color(0.30, 0.32, 0.36))
                card(x: 70, top: 282, width: 308, height: 42)
                fill(canvas, rect: rect(x: 80, top: 346, width: 288, height: 48),
                     color: color(0.10, 0.42, 0.88))
                text(canvas, "Sign In", x: 190, top: 360,
                     size: 17, color: color(1, 1, 1), bold: true)

            case .groceryCheckout:
                header("Grocery Delivery", "Review order")
                text(canvas, "Weekly groceries", x: 46, top: 116,
                     size: 21, color: color(0.10, 0.12, 0.16), bold: true)
                card(x: 36, top: 158, width: 376, height: 132)
                text(canvas, "Milk, bread, and apples", x: 58, top: 184,
                     size: 17, color: color(0.18, 0.20, 0.24), bold: true)
                text(canvas, "Delivery to saved address", x: 58, top: 226,
                     size: 15, color: color(0.34, 0.36, 0.40))
                text(canvas, "Total  $24.18", x: 58, top: 258,
                     size: 17, color: color(0.12, 0.14, 0.18), bold: true)
                fill(canvas, rect: rect(x: 80, top: 320, width: 288, height: 52),
                     color: color(0.08, 0.58, 0.28))
                text(canvas, "Place Order", x: 168, top: 336,
                     size: 18, color: color(1, 1, 1), bold: true)
                text(canvas, "Final purchase confirmation", x: 124, top: 396,
                     size: 14, color: color(0.46, 0.48, 0.52))

            case .reportRemoved:
                header("Documents", "Quarterly report")
                text(canvas, "Quarterly Report", x: 116, top: 126,
                     size: 24, color: color(0.10, 0.12, 0.16), bold: true)
                card(x: 42, top: 188, width: 364, height: 144,
                     fillColor: color(1.0, 0.94, 0.94))
                text(canvas, "REPORT REMOVED", x: 132, top: 214,
                     size: 19, color: color(0.68, 0.10, 0.12), bold: true)
                text(canvas, "This report is no longer available.", x: 76, top: 260,
                     size: 17, color: color(0.24, 0.26, 0.30), bold: true)
                text(canvas, "Ask the owner for a new copy.", x: 96, top: 298,
                     size: 16, color: color(0.34, 0.36, 0.40))

            case .windowsOnlyApplication:
                header("macOS", "Application unavailable")
                card(x: 48, top: 122, width: 352, height: 236,
                     fillColor: color(0.97, 0.97, 0.98))
                text(canvas, "Contoso CAD", x: 148, top: 154,
                     size: 23, color: color(0.10, 0.12, 0.16), bold: true)
                text(canvas, "CAN'T OPEN THIS APPLICATION", x: 88, top: 208,
                     size: 16, color: color(0.68, 0.10, 0.12), bold: true)
                text(canvas, "Contoso CAD is available only for Windows.", x: 64, top: 254,
                     size: 15, color: color(0.22, 0.24, 0.28), bold: true)
                text(canvas, "This Mac cannot run it.", x: 126, top: 292,
                     size: 16, color: color(0.34, 0.36, 0.40))
                fill(canvas, rect: rect(x: 170, top: 374, width: 108, height: 40),
                     color: color(0.88, 0.89, 0.91))
                text(canvas, "OK", x: 212, top: 386,
                     size: 16, color: color(0.12, 0.14, 0.18), bold: true)

            case .calendarNextWeekReached:
                header("Family Calendar", "Household schedule")
                card(x: 20, top: 110, width: 408, height: 250)
                text(canvas, "August 17–23", x: 40, top: 134,
                     size: 18, color: color(0.12, 0.14, 0.18), bold: true)
                text(canvas, "NEXT WEEK IS NOW VISIBLE", x: 104, top: 194,
                     size: 16, color: color(0.10, 0.42, 0.20), bold: true)
                text(canvas, "Wed   School orientation", x: 40, top: 246,
                     size: 16, color: color(0.18, 0.20, 0.24))
                text(canvas, "Sat   Family picnic", x: 40, top: 292,
                     size: 16, color: color(0.18, 0.20, 0.24))

            case .photoAlbumOpened:
                header("Finder", "Summer Picnic")
                text(canvas, "Summer Picnic", x: 138, top: 104,
                     size: 23, color: color(0.10, 0.12, 0.16), bold: true)
                for index in 0 ..< 3 {
                    let x = CGFloat(34 + index * 136)
                    card(x: x, top: 160, width: 110, height: 132,
                         fillColor: [
                            color(0.76, 0.88, 0.96),
                            color(0.84, 0.93, 0.76),
                            color(0.96, 0.84, 0.72),
                         ][index])
                    text(canvas, "Photo \(index + 1)", x: x + 24, top: 260,
                         size: 14, color: color(0.12, 0.14, 0.18), bold: true)
                }
                text(canvas, "3 photos", x: 188, top: 350,
                     size: 15, color: color(0.34, 0.36, 0.40), bold: true)
            }
        }
    }

    static func localDirectoryResult(
        caretVisible: Bool,
        showsSubmittedResult: Bool = true
    ) throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.96, 0.98, 1.0))
            fill(canvas, rect: rect(x: 0, top: 0, width: 448, height: 58),
                 color: color(0.08, 0.23, 0.56))
            text(canvas, "Local Browser Workbench", x: 22, top: 17,
                 size: 20, color: color(1, 1, 1), bold: true)
            text(canvas, "Downtown branch directory", x: 28, top: 86,
                 size: 23, color: color(0.08, 0.10, 0.16), bold: true)
            fill(canvas, rect: rect(x: 28, top: 144, width: 392, height: 58),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 28, top: 144, width: 392, height: 58),
                   color: color(0.10, 0.42, 0.88), width: 3)
            text(canvas, "downtown branch hours", x: 48, top: 162,
                 size: 18, color: color(0.08, 0.10, 0.16), bold: true)
            if caretVisible {
                fill(canvas, rect: rect(x: 256, top: 158, width: 3, height: 30),
                     color: color(0.04, 0.06, 0.10))
            }
            if showsSubmittedResult {
                fill(
                    canvas,
                    rect: rect(x: 28, top: 230, width: 392, height: 82),
                    color: color(0.90, 0.98, 0.92))
                text(
                    canvas,
                    "Downtown branch hours — Today: 9:00 AM–5:00 PM",
                    x: 42,
                    top: 258,
                    size: 16,
                    color: color(0.06, 0.36, 0.16),
                    bold: true)
                text(canvas, "SUBMIT EVENTS  1", x: 142, top: 356,
                     size: 16, color: color(0.28, 0.30, 0.34), bold: true)
            }
        }
    }

    static func localBrowserEvidence(
        lines: [String]
    ) throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.97, 0.98, 1.0))
            fill(
                canvas,
                rect: rect(x: 0, top: 0, width: 448, height: 58),
                color: color(0.08, 0.23, 0.56))
            text(
                canvas,
                "Local Browser Workbench",
                x: 22,
                top: 17,
                size: 20,
                color: color(1, 1, 1),
                bold: true)
            for (index, line) in lines.enumerated() {
                text(
                    canvas,
                    line,
                    x: 28,
                    top: CGFloat(104 + index * 78),
                    size: 18,
                    color: color(0.08, 0.10, 0.16),
                    bold: true)
            }
        }
    }

    static func deliveryQuote() throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.98, 0.98, 0.98))
            fill(canvas, rect: rect(x: 0, top: 0, width: 448, height: 58),
                 color: color(0.86, 0.08, 0.12))
            text(canvas, "DoorDash — Review delivery", x: 22, top: 17,
                 size: 21, color: color(1, 1, 1), bold: true)
            text(canvas, "Pizzeria Uno", x: 24, top: 76,
                 size: 22, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "1 × Large Pepperoni Pizza", x: 24, top: 111,
                 size: 16, color: color(0.12, 0.12, 0.14), bold: true)
            text(canvas, "Delivery to: Saved home address", x: 24, top: 137,
                 size: 13, color: color(0.34, 0.34, 0.38))
            fill(canvas, rect: rect(x: 20, top: 170, width: 408, height: 196),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 20, top: 170, width: 408, height: 196),
                   color: color(0.82, 0.82, 0.84), width: 1)
            let rows = [
                ("Subtotal", "$24.99"),
                ("Delivery fee", "$2.99"),
                ("Service fee", "$3.75"),
                ("Tax", "$2.78"),
                ("TOTAL", "$34.51"),
                ("ETA", "28–38 min"),
            ]
            for (index, row) in rows.enumerated() {
                let top = CGFloat(187 + index * 28)
                let emphasized = index >= 4
                text(canvas, row.0, x: 38, top: top, size: emphasized ? 16 : 14,
                     color: color(0.12, 0.12, 0.14), bold: emphasized)
                text(canvas, row.1, x: 316, top: top, size: emphasized ? 16 : 14,
                     color: color(0.12, 0.12, 0.14), bold: emphasized)
            }
            fill(canvas, rect: rect(x: 76, top: 386, width: 296, height: 42),
                 color: color(0.90, 0.92, 0.94))
            text(canvas, "QUOTE READY — CHECKOUT DISABLED", x: 97, top: 398,
                 size: 14, color: color(0.18, 0.20, 0.24), bold: true)
        }
    }

    /// Recreates the exact system sheet observed over the real DoorDash sign-
    /// in screen. The wording and both choices are intentionally literal so
    /// the local OCR gate is tested against the shipped macOS prompt rather
    /// than a simplified permission placeholder.
    static func screenCaptureConsentPrompt()
        throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.95, 0.95, 0.96))
            text(canvas, "DoorDash", x: 20, top: 18,
                 size: 20, color: color(0.86, 0.08, 0.12), bold: true)
            text(canvas, "Sign in to access your credits and discounts",
                 x: 32, top: 76, size: 15,
                 color: color(0.18, 0.18, 0.20), bold: true)
            text(canvas, "Continue with Google", x: 52, top: 112,
                 size: 14, color: color(0.28, 0.28, 0.30))
            text(canvas, "Continue with Apple", x: 52, top: 146,
                 size: 14, color: color(0.28, 0.28, 0.30))

            fill(canvas, rect: rect(x: 28, top: 35, width: 392, height: 382),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 28, top: 35, width: 392, height: 382),
                   color: color(0.68, 0.68, 0.70), width: 2)
            text(canvas, "“RemoteDesktopHost” is requesting to", x: 50, top: 58,
                 size: 16, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "bypass the system private window picker", x: 50, top: 84,
                 size: 16, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "and directly access your screen and audio.", x: 50, top: 110,
                 size: 16, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "This will allow RemoteDesktopHost to", x: 50, top: 151,
                 size: 15, color: color(0.20, 0.20, 0.22))
            text(canvas, "record your screen and system audio,", x: 50, top: 176,
                 size: 15, color: color(0.20, 0.20, 0.22))
            text(canvas, "including personal or sensitive information", x: 50, top: 201,
                 size: 15, color: color(0.20, 0.20, 0.22))
            text(canvas, "that may be visible or audible.", x: 50, top: 226,
                 size: 15, color: color(0.20, 0.20, 0.22))
            fill(canvas, rect: rect(x: 50, top: 274, width: 348, height: 44),
                 color: color(0.12, 0.44, 0.92))
            text(canvas, "Allow", x: 202, top: 287,
                 size: 17, color: color(1, 1, 1), bold: true)
            fill(canvas, rect: rect(x: 50, top: 334, width: 348, height: 44),
                 color: color(0.91, 0.91, 0.93))
            text(canvas, "Open System Settings", x: 138, top: 347,
                 size: 17, color: color(0.08, 0.08, 0.09), bold: true)
        }
    }

    static func deliverySignInWall() throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.98, 0.98, 0.98))
            fill(canvas, rect: rect(x: 0, top: 0, width: 448, height: 52),
                 color: color(1, 1, 1))
            text(canvas, "DoorDash", x: 22, top: 16,
                 size: 19, color: color(0.86, 0.08, 0.12), bold: true)
            text(canvas, "1. Sign in or sign up to place order", x: 24, top: 69,
                 size: 19, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "Sign in to access your credits and discounts", x: 24, top: 103,
                 size: 13, color: color(0.24, 0.24, 0.27))
            let providers = [
                "Continue with Google",
                "Continue with Facebook",
                "Continue with Apple",
            ]
            for (index, provider) in providers.enumerated() {
                let top = CGFloat(139 + index * 42)
                fill(canvas, rect: rect(x: 24, top: top, width: 250, height: 32),
                     color: color(1, 1, 1))
                stroke(canvas, rect: rect(x: 24, top: top, width: 250, height: 32),
                       color: color(0.72, 0.72, 0.75), width: 1)
                text(canvas, provider, x: 50, top: top + 9,
                     size: 12, color: color(0.12, 0.12, 0.14), bold: true)
            }
            text(canvas, "or continue with email", x: 70, top: 273,
                 size: 12, color: color(0.38, 0.38, 0.41))
            text(canvas, "Email", x: 24, top: 304,
                 size: 12, color: color(0.10, 0.10, 0.12), bold: true)
            text(canvas, "Required", x: 188, top: 304,
                 size: 11, color: color(0.72, 0.08, 0.10))
            fill(canvas, rect: rect(x: 24, top: 329, width: 250, height: 38),
                 color: color(0.86, 0.08, 0.12))
            text(canvas, "Continue to Sign In", x: 80, top: 341,
                 size: 13, color: color(1, 1, 1), bold: true)
            text(canvas, "Jamra Special 14 inch", x: 300, top: 102,
                 size: 12, color: color(0.12, 0.12, 0.14), bold: true)
            text(canvas, "$26.99", x: 352, top: 132,
                 size: 13, color: color(0.12, 0.12, 0.14), bold: true)
        }
    }

    static func deliveryAddressEntry() throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.98, 0.98, 0.98))
            text(canvas, "Delivery address", x: 42, top: 10,
                 size: 15, color: color(0.20, 0.20, 0.24), bold: true)
            fill(canvas, rect: rect(x: 40, top: 34, width: 368, height: 64),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 40, top: 34, width: 368, height: 64),
                   color: color(0.86, 0.08, 0.12), width: 3)
            text(canvas, "Enter a street address", x: 58, top: 56,
                 size: 17, color: color(0.48, 0.48, 0.52))
            text(canvas, "Where should we deliver?", x: 40, top: 132,
                 size: 23, color: color(0.10, 0.10, 0.12), bold: true)
            text(canvas, "DoorDash quote setup", x: 40, top: 168,
                 size: 14, color: color(0.46, 0.46, 0.50))
            text(canvas, "Order details", x: 40, top: 230,
                 size: 16, color: color(0.12, 0.12, 0.14), bold: true)
            text(canvas, "Pizzeria Uno", x: 40, top: 262,
                 size: 15, color: color(0.18, 0.18, 0.20))
            text(canvas, "1 × Large Pepperoni Pizza", x: 40, top: 290,
                 size: 15, color: color(0.18, 0.18, 0.20))
            fill(canvas, rect: rect(x: 128, top: 365, width: 192, height: 44),
                 color: color(0.84, 0.85, 0.87))
            text(canvas, "Continue (address needed)", x: 146, top: 379,
                 size: 13, color: color(0.42, 0.43, 0.46), bold: true)
        }
    }

    static func deliveryResultsAboveFold() throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.98, 0.98, 0.98))
            fill(canvas, rect: rect(x: 0, top: 0, width: 448, height: 58),
                 color: color(0.86, 0.08, 0.12))
            text(canvas, "DoorDash — Delivery result", x: 22, top: 17,
                 size: 21, color: color(1, 1, 1), bold: true)
            text(canvas, "Pizzeria Uno", x: 24, top: 82,
                 size: 22, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "1 × Large Pepperoni Pizza", x: 24, top: 120,
                 size: 16, color: color(0.12, 0.12, 0.14), bold: true)
            text(canvas, "Delivery to 200 Market Street", x: 24, top: 151,
                 size: 14, color: color(0.34, 0.34, 0.38))
            fill(canvas, rect: rect(x: 24, top: 199, width: 386, height: 158),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 24, top: 199, width: 386, height: 158),
                   color: color(0.82, 0.82, 0.84), width: 1)
            text(canvas, "Delivery option found", x: 116, top: 226,
                 size: 19, color: color(0.12, 0.42, 0.22), bold: true)
            text(canvas, "Complete price breakdown and ETA", x: 78, top: 270,
                 size: 16, color: color(0.18, 0.20, 0.24), bold: true)
            text(canvas, "are below this viewport", x: 126, top: 302,
                 size: 16, color: color(0.18, 0.20, 0.24), bold: true)
            fill(canvas, rect: rect(x: 420, top: 72, width: 8, height: 334),
                 color: color(0.84, 0.85, 0.87))
            fill(canvas, rect: rect(x: 420, top: 74, width: 8, height: 96),
                 color: color(0.38, 0.40, 0.44))
            text(canvas, "Scroll down to view the full quote", x: 88, top: 388,
                 size: 16, color: color(0.10, 0.42, 0.82), bold: true)
        }
    }

    static func deliveryFeeDetailsAboveFold() throws -> ComputerUseScreenObservation {
        try observation { canvas in
            fill(canvas, color: color(0.98, 0.98, 0.98))
            fill(canvas, rect: rect(x: 0, top: 0, width: 448, height: 58),
                 color: color(0.86, 0.08, 0.12))
            text(canvas, "DoorDash — Quote details", x: 22, top: 17,
                 size: 21, color: color(1, 1, 1), bold: true)
            text(canvas, "Pizzeria Uno", x: 24, top: 78,
                 size: 21, color: color(0.08, 0.08, 0.09), bold: true)
            text(canvas, "1 × Large Pepperoni Pizza", x: 24, top: 112,
                 size: 16, color: color(0.12, 0.12, 0.14), bold: true)
            fill(canvas, rect: rect(x: 24, top: 158, width: 384, height: 170),
                 color: color(1, 1, 1))
            stroke(canvas, rect: rect(x: 24, top: 158, width: 384, height: 170),
                   color: color(0.82, 0.82, 0.84), width: 1)
            text(canvas, "Subtotal", x: 46, top: 184,
                 size: 15, color: color(0.12, 0.12, 0.14))
            text(canvas, "$24.99", x: 320, top: 184,
                 size: 15, color: color(0.12, 0.12, 0.14))
            text(canvas, "Delivery fee", x: 46, top: 226,
                 size: 15, color: color(0.12, 0.12, 0.14))
            text(canvas, "$2.99", x: 320, top: 226,
                 size: 15, color: color(0.12, 0.12, 0.14))
            text(canvas, "More fees, tax, total, and ETA below", x: 66, top: 282,
                 size: 15, color: color(0.18, 0.20, 0.24), bold: true)
            fill(canvas, rect: rect(x: 420, top: 72, width: 8, height: 334),
                 color: color(0.84, 0.85, 0.87))
            fill(canvas, rect: rect(x: 420, top: 204, width: 8, height: 96),
                 color: color(0.38, 0.40, 0.44))
            text(canvas, "Scroll down again for the complete quote", x: 68, top: 376,
                 size: 16, color: color(0.10, 0.42, 0.82), bold: true)
        }
    }

    private static func observation(
        drawing: (CGContext) -> Void
    ) throws -> ComputerUseScreenObservation {
        guard let canvas = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureRenderingError.couldNotRenderFixture
        }
        drawing(canvas)
        guard let image = canvas.makeImage() else {
            throw FixtureRenderingError.couldNotRenderFixture
        }
        return ComputerUseScreenObservation(
            image: CIImage(cgImage: image),
            displayBounds: CGRect(x: 0, y: 0, width: width, height: height),
            frontmostWindowBounds: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height))
    }

    private static func rect(
        x: CGFloat,
        top: CGFloat,
        width: CGFloat,
        height rectHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: x,
            y: CGFloat(height) - top - rectHeight,
            width: width,
            height: rectHeight)
    }

    private static func fill(_ canvas: CGContext, color: CGColor) {
        fill(
            canvas,
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            color: color)
    }

    private static func fill(
        _ canvas: CGContext,
        rect: CGRect,
        color: CGColor
    ) {
        canvas.setFillColor(color)
        canvas.fill(rect)
    }

    private static func stroke(
        _ canvas: CGContext,
        rect: CGRect,
        color: CGColor,
        width: CGFloat
    ) {
        canvas.setStrokeColor(color)
        canvas.setLineWidth(width)
        canvas.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
    }

    private static func text(
        _ canvas: CGContext,
        _ value: String,
        x: CGFloat,
        top: CGFloat,
        size: CGFloat,
        color: CGColor,
        bold: Bool = false
    ) {
        let font = CTFontCreateWithName(
            (bold ? "Helvetica-Bold" : "Helvetica") as CFString,
            size,
            nil)
        let attributed = NSAttributedString(
            string: value,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        canvas.textPosition = CGPoint(
            x: x,
            y: CGFloat(height) - top - size)
        CTLineDraw(line, canvas)
    }

    private static func color(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat
    ) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, 1])!
    }
}

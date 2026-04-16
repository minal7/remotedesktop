import XCTest
@testable import RemoteDesktop

final class InputAndDiscoveryTests: XCTestCase {
    func test_localHostAdvertisement_roundTripsServiceName() {
        let name = LocalHostAdvertisement.serviceName(hostname: "Studio Mac", code: "123456")
        let parsed = LocalHostAdvertisement.parse(serviceName: name)

        XCTAssertEqual(parsed?.hostname, "Studio Mac")
        XCTAssertEqual(parsed?.code, "123456")
    }

    func test_localHostAdvertisement_rejects_invalid_names() {
        XCTAssertNil(LocalHostAdvertisement.parse(serviceName: "Studio Mac"))
        XCTAssertNil(LocalHostAdvertisement.parse(serviceName: "Studio Mac [12ab56]"))
    }

    func test_softKeyboardShortcutMapper_maps_command_c() {
        let mapped = SoftKeyboardShortcutMapper.map("c", baseModifiers: SoftModifier.cmd.mask)

        XCTAssertEqual(mapped?.usage, 0x06)
        XCTAssertEqual(mapped?.modifiers, SoftModifier.cmd.mask)
    }

    func test_softKeyboardShortcutMapper_adds_shift_for_uppercase() {
        let mapped = SoftKeyboardShortcutMapper.map("A", baseModifiers: 0)

        XCTAssertEqual(mapped?.usage, 0x04)
        XCTAssertEqual(mapped?.modifiers, SoftModifier.shift.mask)
    }
}

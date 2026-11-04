import Foundation
import XCTest
@testable import RemoteDesktopHost

#if DEBUG
final class DebugResidentHostConfigurationTests: XCTestCase {
    func testSelectorRequiresOnlyTheExactResidentArgument() {
        XCTAssertTrue(DebugResidentHostConfiguration.isSelected(
            arguments: ["RemoteDesktopHost", "--debug-r0-resident-host"]))
        XCTAssertFalse(DebugResidentHostConfiguration.isSelected(
            arguments: ["RemoteDesktopHost", "--debug-r0-resident-host-extra"]))
        XCTAssertTrue(DebugResidentHostConfiguration.isSelected(
            arguments: ["RemoteDesktopHost"],
            environment: [DebugResidentHostConfiguration.identityEnvironmentKey:
                "8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2"]))
        XCTAssertNil(DebugResidentHostConfiguration.parse(
            arguments: ["RemoteDesktopHost", "--debug-r0-resident-host", "unexpected"],
            environment: [DebugResidentHostConfiguration.identityEnvironmentKey:
                "8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2"]))
    }

    func testParseRequiresWellFormedDedicatedHostIdentity() {
        let args = ["RemoteDesktopHost", "--debug-r0-resident-host"]
        let key = DebugResidentHostConfiguration.identityEnvironmentKey
        XCTAssertNil(DebugResidentHostConfiguration.parse(
            arguments: args, environment: [:]))
        XCTAssertNil(DebugResidentHostConfiguration.parse(
            arguments: args, environment: [key: "release-host"]))

        let configuration = DebugResidentHostConfiguration.parse(
            arguments: args,
            environment: [key: "8f8f6c31-7bf6-4c51-ae04-5b94b01a59a2"])
        XCTAssertEqual(
            configuration?.hostID,
            "8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2")
        XCTAssertEqual(
            configuration?.lockIdentity,
            "com.threadmark.remotedesktop.host.r0-test")
        XCTAssertEqual(configuration?.hostDisplayName, "Remote Desktop R0 Test")
        XCTAssertNotEqual(
            DebugResidentHostConfiguration.credentialService,
            LocalComputerUseCredentialStore.defaultService)
        XCTAssertTrue(
            configuration?.taskLedgerURL.path.contains("Remote Desktop Host R0 Test") == true)
        XCTAssertEqual(configuration?.mode, .r0)
        XCTAssertEqual(configuration?.allowsExternalComputerUseServices, true)
        XCTAssertEqual(configuration?.allowsPersonalMemory, true)
    }

    func testLatencySelectorHasDistinctIdentityAndDisablesOptionalServices() throws {
        let argument = DebugResidentHostConfiguration.latencyArgument
        let key = DebugResidentHostConfiguration.latencyIdentityEnvironmentKey
        let environment = [key: "8f8f6c31-7bf6-4c51-ae04-5b94b01a59a2"]
        XCTAssertTrue(DebugResidentHostConfiguration.isSelected(arguments: ["host"], environment: environment))
        XCTAssertNil(DebugResidentHostConfiguration.parse(arguments: ["host", argument], environment: [:]))
        XCTAssertNil(DebugResidentHostConfiguration.parse(arguments: ["host", argument, "extra"], environment: environment))
        XCTAssertNil(DebugResidentHostConfiguration.parse(arguments: ["host", argument], environment: [key: "invalid"]))
        XCTAssertNil(DebugResidentHostConfiguration.parse(arguments: ["host", argument], environment: environment.merging(
            [DebugResidentHostConfiguration.identityEnvironmentKey: environment[key]!]) { first, _ in first }))
        let config = try XCTUnwrap(DebugResidentHostConfiguration.parse(arguments: ["host", argument], environment: environment))
        XCTAssertEqual(config.hostID, "8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2")
        XCTAssertEqual(config.mode, .latency)
        XCTAssertEqual(config.hostDisplayName, Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        XCTAssertEqual(config.lockIdentity, "com.threadmark.remotedesktop.host.latency-test")
        XCTAssertNotEqual(config.credentialServiceName, DebugResidentHostConfiguration.credentialService)
        XCTAssertNotEqual(config.credentialServiceName, LocalComputerUseCredentialStore.defaultService)
        XCTAssertTrue(config.taskLedgerURL.path.contains("Remote Desktop Host Latency Test"))
        XCTAssertFalse(config.allowsExternalComputerUseServices)
        XCTAssertFalse(config.allowsPersonalMemory)
    }
}

#endif

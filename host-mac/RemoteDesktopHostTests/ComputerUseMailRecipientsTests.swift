import XCTest
@testable import RemoteDesktopHost

final class ComputerUseMailRecipientsTests: XCTestCase {
    func testExplicitMailboxAddressesBypassContactsLookup() async throws {
        let arguments = mailArguments(to: "one@example.invalid, two@example.invalid",
            cc: "copy@example.invalid", bcc: "blind@example.invalid")
        let lookup = LookupRecorder()
        var resolver = try ComputerUseMailRecipients(arguments: arguments)

        let resolution = try await resolver.resolve { _ in
            await lookup.record("unexpected")
            return []
        }

        XCTAssertEqual(resolution, .ready(arguments))
        let lookupCount = await lookup.count
        XCTAssertEqual(lookupCount, 0)
    }

    func testUniqueContactResolvesWithoutChangingOtherMailFields() async throws {
        let arguments = mailArguments(to: "Jordan Lee", cc: "copy@example.invalid")
        let lookup = LookupRecorder()
        var resolver = try ComputerUseMailRecipients(arguments: arguments)
        let resolution = try await resolver.resolve { name in
            await lookup.record(name)
            return [.init(name: "Jordan Lee", address: "jordan@example.invalid")]
        }

        let queries = await lookup.queries
        XCTAssertEqual(queries, ["Jordan Lee"])
        var expected = arguments
        expected["to"] = .string("jordan@example.invalid")
        XCTAssertEqual(resolution, .ready(expected))
    }

    func testAmbiguousContactRequiresAnOfferedMatchBeforeResolving() async throws {
        let arguments = mailArguments(to: "Jordan Lee")
        let matches = [
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.work@example.invalid"),
            ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.home@example.invalid"),
        ]
        let lookup = LookupRecorder()
        var resolver = try ComputerUseMailRecipients(arguments: arguments)
        guard case .choose(name: "Jordan Lee", field: "to", index: 0, matches: let offeredMatches) =
            try await resolver.resolve(lookup: { name in
                await lookup.record(name)
                return matches
            }) else {
            return XCTFail("An ambiguous contact must be presented as a bounded choice.")
        }
        XCTAssertEqual(offeredMatches.sorted { $0.address < $1.address }, matches.sorted { $0.address < $1.address },
            "The resolver may sort choices, but must preserve every offered name and address.")

        let selected = try XCTUnwrap(offeredMatches.first { $0.address == matches[1].address })
        try resolver.select(address: selected.address, field: "to", index: 0)
        let resumed = try await resolver.resolve { _ in
            await lookup.record("unexpected second lookup")
            return []
        }
        var expected = arguments
        expected["to"] = .string(selected.address)
        XCTAssertEqual(resumed, .ready(expected))
        let queries = await lookup.queries
        XCTAssertEqual(queries, ["Jordan Lee"])
    }

    func testMissingContactReturnsAQuestionWithoutInventingAnAddress() async throws {
        let arguments = mailArguments(to: "Jordan Lee")
        var resolver = try ComputerUseMailRecipients(arguments: arguments)
        let resolution = try await resolver.resolve(lookup: { _ in [] })

        guard case .missing(let question) = resolution else {
            return XCTFail("A missing contact must return a focused recipient question.")
        }
        XCTAssertTrue(question.contains("Jordan Lee"))
        XCTAssertNil((resolution.readyArguments)?["to"])
    }

    func testInvalidNonrecipientFieldsAreRejectedBeforeContactsLookup() async throws {
        var arguments = mailArguments(to: "Jordan Lee")
        arguments["subject"] = .string("Bad\nsubject")
        let lookup = LookupRecorder()
        do {
            var resolver = try ComputerUseMailRecipients(arguments: arguments)
            _ = try await resolver.resolve { name in
                await lookup.record(name)
                return []
            }
            XCTFail("The Mail structure must be validated before resolving recipient names.")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .invalidArguments(
                "The Mail subject is too long or contains an unsupported control character."))
        }
        let lookupCount = await lookup.count
        XCTAssertEqual(lookupCount, 0)
    }

    private func mailArguments(to: String, cc: String = "", bcc: String = "") -> [String: MCPJSONValue] {
        [
            "to": .string(to),
            "cc": .string(cc),
            "bcc": .string(bcc),
            "subject": .string("Quarterly review"),
            "body": .string("Please review the attached file."),
            "send_now": .bool(true),
            "attachment_paths": .array([.string("/tmp/Board Review.pptx")]),
        ]
    }
}

private extension ComputerUseMailRecipients.Resolution {
    var readyArguments: [String: MCPJSONValue]? {
        guard case .ready(let arguments) = self else { return nil }
        return arguments
    }
}

private actor LookupRecorder {
    private(set) var queries: [String] = []
    var count: Int { queries.count }

    func record(_ name: String) { queries.append(name) }
}

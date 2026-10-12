import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared regression coverage; no assertions have executed in this repair.
@MainActor
final class ComputerUseBrowserFormEffectScopeTests: XCTestCase {

    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == "Query" })
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Caller-supplied semantics for authored fixtures, never a production policy.
@MainActor
enum FormEffectScopeFixture {
    static func rows(_ input: ComputerUseBrowserActionInput, relevant: [String: Int], unrelated: Set<String>,
                     extraEvidence: [String] = []) throws -> [[String: Any]] {
        try input.effectReviewNextControlIDs.map { id in
            let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
            let requirement = relevant[label]
            return ["control":id,"relationship":requirement != nil ? "relevant" : (unrelated.contains(label) ? "unrelated" : "unknown"),
                "requirements":requirement.map { [$0] } ?? [],"evidence":[id] + extraEvidence]
        }
    }
    static func response(_ input: ComputerUseBrowserActionInput, relevant: [String: Int] = [:], unrelated: Set<String> = [],
                         extraEvidence: [String] = [], editing: [String: [Int]] = [:], retaining: [String: [Int]] = [:],
                         deferring: [String: [Int]] = [:], preserving: [String: Int] = [:]) throws -> String? {
        guard input.formEffectScope != nil else { return nil }
        var references = relevant.mapValues { [$0] }
        for decisions in [editing, retaining, deferring, preserving.mapValues { [$0] }] {
            for (label, indices) in decisions { references[label] = indices }
        }
        if !input.effectReviewNextControlIDs.isEmpty {
            var rows = try rows(input, relevant: references.compactMapValues(\.first), unrelated: unrelated, extraEvidence: extraEvidence)
            for index in rows.indices {
                let id = try XCTUnwrap(rows[index]["control"] as? String)
                let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
                if let indices = references[label] { rows[index]["requirements"] = indices }
            }
            return try ResearchAnswerFixture.json(["review_controls":rows])
        }
        var intentions: [[String: Any]] = []
        for (name, ids, decisions) in [("edit",input.effectAdditionalEditControlIDs,editing),
                ("retain",input.effectAdditionalRetainedControlIDs,retaining), ("deferred",input.effectAdditionalDeferredControlIDs,deferring)] {
            for id in ids where intentions.count < 4 {
                let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
                if let indices = decisions[label] { intentions.append(["control":id,"disposition":name,"requirements":indices]) }
            }
        }
        if !intentions.isEmpty { return try ResearchAnswerFixture.json(["plan_fields":intentions]) }
        let preservation: [[String: Any]] = input.effectAdditionalPreservationControlIDs.compactMap { id in
            guard let label = input.evidence.page.controls.first(where: { $0.id == id })?.label,
                  let index = preserving[label] else { return nil }
            return ["control":id,"requirement":index]
        }
        if !preservation.isEmpty { return try ResearchAnswerFixture.json(["preserve_controls":preservation]) }
        let reading: [[String: Any]] = input.effectAdditionalReadControlIDs.compactMap { id in
            guard let label = input.evidence.page.controls.first(where: { $0.id == id })?.label,
                  let index = relevant[label] else { return nil }
            return ["control":id,"requirement":index]
        }
        return reading.isEmpty ? nil : try ResearchAnswerFixture.json(["extend_inspection":reading])
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserActionPlannerTests: XCTestCase {

    func testLoginHandoffLabelsRequireAnExplicitSignInEntry() {
        for label in ["Sign in", " Log In \n", "LOGIN", "Sign in to continue", "Sign in to your account", "Sign in with Google", "Continue with Apple"] {
            XCTAssertTrue(ComputerUseBrowserLoginHandoffTarget.recognizes(label), label)
        }
        for label in ["", "Continue", "Create account", "Sign out", "Login help", "Sign in policy", "Do not sign in", "Sign in and buy", "Continue with payment", "Account", String(repeating: "Sign in ", count: 40)] {
            XCTAssertFalse(ComputerUseBrowserLoginHandoffTarget.recognizes(label), label)
        }
    }

    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func formReview(_ input: ComputerUseBrowserActionInput) throws -> String? {
        let heading = input.evidence.page.texts.first { $0.text == "Newsletter preferences" }?.id
        var unrelated: Set<String> = ["Newsletter", "Subscribe"]
        if heading != nil { unrelated.insert("") }
        return try FormEffectScopeFixture.response(input, unrelated: unrelated, extraEvidence: heading.map { [$0] } ?? [], editing: ["Query":[0]])
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func local(_ transport: ActionPlannerTransport) throws -> ComputerUseLocalBrowserActionPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value",
            modelAlias: ComputerUseNativeTextRuntimeInputs.modelAlias), transport: transport)
    }
}

private actor ActionPlannerTransport: ComputerUseTextModelTransport {
    let count: Int
    let cancelAt: String?
    private(set) var requests: [URLRequest] = []
    init(count: Int = 100, cancelAt: String? = nil) { self.count = count; self.cancelAt = cancelAt }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest)
        if cancelAt == "count" { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        if cancelAt == "completion" { withUnsafeCurrentTask { $0?.cancel() } }
        return try JSONSerialization.data(withJSONObject: ["model":ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices":[["index":0, "finish_reason":"stop", "message":["role":"assistant", "content":#"{"read_results":true}"#]]]])
    }
}

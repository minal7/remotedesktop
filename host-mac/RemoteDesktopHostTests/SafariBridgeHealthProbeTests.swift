import XCTest
@testable import RemoteDesktopHost

@MainActor
final class SafariBridgeHealthProbeTests: XCTestCase {
    func testOnlyCallerSuppliedLoopbackHTTPURLIsAccepted() async {
        for url in ["http://127.0.0.1:8765/fixture", "http://localhost:8765/fixture"] {
            do {
                _ = try await SafariBridgeHealthProbe.run(testURL: url, sampleCount: 99)
                XCTFail("Expected sample count validation for \(url)")
            } catch let error as SafariBridgeHealthProbeError {
                XCTAssertEqual(error, .invalidSampleCount)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsPublicAndNonHTTPURLsBeforeTouchingSafari() async {
        for url in ["https://example.com/", "http://example.com/", "http://[::1]:8765/fixture", "file:///tmp/page.html", "http://user:secret@127.0.0.1/"] {
            do {
                _ = try await SafariBridgeHealthProbe.run(testURL: url)
                XCTFail("Expected URL validation for \(url)")
            } catch let error as SafariBridgeHealthProbeError {
                XCTAssertEqual(error, .invalidTestURL)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

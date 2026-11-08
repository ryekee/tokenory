import XCTest
@testable import Tokenory

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() throws {
        XCTAssertTrue(try ReleaseVersion("v0.10.0") > ReleaseVersion("0.9.9"))
        XCTAssertTrue(try ReleaseVersion("1.0.0") > ReleaseVersion("0.99.99"))
        XCTAssertEqual(try ReleaseVersion("v0.1.1"), try ReleaseVersion("0.1.1"))
        for invalid in ["", "latest", "1.2", "1.2.3-beta", "1..3", "-1.2.3"] {
            XCTAssertThrowsError(try ReleaseVersion(invalid))
        }
    }

    private static func payload(tag: String = "v0.1.1", draft: Bool = false, prerelease: Bool = false,
                                url: String = "https://github.com/ryekee/tokenory/releases/tag/v0.1.1") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease])
    }

    func testReleaseBoundary() throws {
        XCTAssertEqual(try AppRelease.decode(Self.payload()).tag, "v0.1.1")
        XCTAssertThrowsError(try AppRelease.decode(Self.payload(draft: true)))
        XCTAssertThrowsError(try AppRelease.decode(Self.payload(prerelease: true)))
        XCTAssertThrowsError(try AppRelease.decode(Self.payload(url: "https://example.com/release")))
        XCTAssertThrowsError(try AppRelease.decode(Data("{}".utf8)))
    }

    @MainActor
    func testLatestUpdateUsesGitHubAndComparesInstalledVersion() async throws {
        for (current, expected) in [("0.1.0", true), ("0.1.1", false), ("0.2.0", false)] {
            let checker = UpdateChecker(currentVersion: current) { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/ryekee/tokenory/releases/latest")
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                return (Self.payload(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let result = try await checker.latestUpdate()
            XCTAssertEqual(result != nil, expected)
        }
    }

    @MainActor
    func testHTTPAndNetworkFailuresAreNotReportedAsUpToDate() async {
        for status in [404, 403, 429, 500] {
            let checker = UpdateChecker(currentVersion: "0.1.1") { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await checker.latestUpdate(); XCTFail("Expected HTTP failure") }
            catch { XCTAssertTrue(error is UpdateError) }
        }
        let checker = UpdateChecker(currentVersion: "0.1.1") { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await checker.latestUpdate(); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }
}

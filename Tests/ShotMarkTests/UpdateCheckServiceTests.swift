import XCTest
@testable import ShotMark

final class UpdateCheckServiceTests: XCTestCase {
    func testLiveOfficialReleaseFeedWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["SHOTMARK_UPDATE_INTEGRATION"] == "1" else {
            throw XCTSkip("Live GitHub update integration is disabled")
        }
        let expectation = expectation(description: "Official release feed")
        let token = ProcessInfo.processInfo.environment["SHOTMARK_UPDATE_TEST_TOKEN"]
        UpdateCheckService(authorizationToken: token).check(currentVersion: "0.0.0") { result in
            guard case .success(.updateAvailable(let release)) = result else {
                XCTFail("Expected the official feed to return a stable release, got \(result)")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(release.releasePageURL.host, "github.com")
            XCTAssertEqual(release.downloadURL.host, "github.com")
            XCTAssertEqual(release.sha256Digest.count, 64)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
    }

    func testVersionComparisonUsesNumericComponents() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.1.9")), try XCTUnwrap(AppVersion("v0.1.10")))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0")), try XCTUnwrap(AppVersion("1.99.99")))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testValidGitHubReleaseFindsDMGAndDigest() throws {
        let result = UpdateCheckService.parse(
            data: releaseData(version: "v0.1.52"),
            response: try response(statusCode: 200),
            installedVersion: try XCTUnwrap(AppVersion("0.1.51")),
            currentVersion: "0.1.51"
        )

        guard case .success(.updateAvailable(let release)) = result else {
            return XCTFail("Expected an available update, got \(result)")
        }
        XCTAssertEqual(release.displayVersion, "0.1.52")
        XCTAssertEqual(release.downloadURL.host, "github.com")
        XCTAssertEqual(release.sha256Digest, String(repeating: "a", count: 64))
    }

    func testCurrentOrOlderReleaseIsUpToDate() throws {
        let result = UpdateCheckService.parse(
            data: releaseData(version: "v0.1.51"),
            response: try response(statusCode: 200),
            installedVersion: try XCTUnwrap(AppVersion("0.1.51")),
            currentVersion: "0.1.51"
        )

        XCTAssertEqual(result, .success(.upToDate(currentVersion: "0.1.51")))
    }

    func testDraftPrereleaseAndNonGitHubAssetsAreRejected() throws {
        let installed = try XCTUnwrap(AppVersion("0.1.51"))
        for data in [
            releaseData(version: "v0.1.52", draft: true),
            releaseData(version: "v0.1.52", prerelease: true),
            releaseData(version: "v0.1.52", downloadURL: "https://example.com/ShotMark.dmg"),
            releaseData(version: "v0.1.52", downloadURL: "https://github.com/another/project/releases/download/v1/ShotMark.dmg"),
            releaseData(version: "v0.1.52", digest: "sha256:invalid")
        ] {
            XCTAssertEqual(
                UpdateCheckService.parse(
                    data: data,
                    response: try response(statusCode: 200),
                    installedVersion: installed,
                    currentVersion: "0.1.51"
                ),
                .failure(.releaseUnavailable)
            )
        }
    }

    func testHTTPFailureAndOversizedResponseAreRejected() throws {
        let installed = try XCTUnwrap(AppVersion("0.1.51"))
        XCTAssertEqual(
            UpdateCheckService.parse(
                data: Data(),
                response: try response(statusCode: 500),
                installedVersion: installed,
                currentVersion: "0.1.51"
            ),
            .failure(.invalidServerResponse)
        )
        XCTAssertEqual(
            UpdateCheckService.parse(
                data: Data(repeating: 0, count: UpdateCheckService.maximumResponseBytes + 1),
                response: try response(statusCode: 200),
                installedVersion: installed,
                currentVersion: "0.1.51"
            ),
            .failure(.responseTooLarge)
        )
    }

    func testAutomaticCheckPolicyHonorsPreferenceAndDailyInterval() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(UpdateCheckPolicy.shouldAutomaticallyCheck(enabled: false, lastCheckedAt: nil, now: now))
        XCTAssertTrue(UpdateCheckPolicy.shouldAutomaticallyCheck(enabled: true, lastCheckedAt: nil, now: now))
        XCTAssertFalse(UpdateCheckPolicy.shouldAutomaticallyCheck(
            enabled: true,
            lastCheckedAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(UpdateCheckPolicy.shouldAutomaticallyCheck(
            enabled: true,
            lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.automaticCheckInterval),
            now: now
        ))
    }

    func testUpdatePreferencesPersistAndDefaultToEnabled() {
        let suiteName = "ShotMarkUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        settings.automaticallyChecksForUpdates = false
        settings.lastUpdateCheckAt = Date(timeIntervalSince1970: 500)

        let restored = AppSettings(defaults: defaults)
        XCTAssertFalse(restored.automaticallyChecksForUpdates)
        XCTAssertEqual(restored.lastUpdateCheckAt, Date(timeIntervalSince1970: 500))
    }

    private func releaseData(
        version: String,
        draft: Bool = false,
        prerelease: Bool = false,
        downloadURL: String = "https://github.com/jeffrey553553-cell/ShotMark/releases/download/v0.1.52/ShotMark.dmg",
        digest: String = "sha256:\(String(repeating: "a", count: 64))"
    ) -> Data {
        Data("""
        {
          "tag_name": "\(version)",
          "html_url": "https://github.com/jeffrey553553-cell/ShotMark/releases/tag/\(version)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-09-01T00:00:00Z",
          "assets": [{
            "name": "ShotMark.dmg",
            "browser_download_url": "\(downloadURL)",
            "digest": "\(digest)"
          }]
        }
        """.utf8)
    }

    private func response(statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: UpdateCheckService.releaseEndpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
    }
}

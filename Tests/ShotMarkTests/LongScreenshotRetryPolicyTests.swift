import XCTest
@testable import ShotMark

final class LongScreenshotRetryPolicyTests: XCTestCase {
    func testDefaultRetryDelaysIncreaseToAllowDynamicContentToSettle() {
        let policy = LongScreenshotRetryPolicy()
        let delays = (1...policy.maximumRetryCount).compactMap(policy.delay(forAttempt:))

        XCTAssertEqual(delays.count, 4)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertGreaterThan(delays.last ?? 0, delays.first ?? 0)
    }

    func testRetryAttemptOutsidePolicyReturnsNil() {
        let policy = LongScreenshotRetryPolicy(delays: [0.1, 0.2])

        XCTAssertNil(policy.delay(forAttempt: 0))
        XCTAssertEqual(policy.delay(forAttempt: 1), 0.1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 0.2)
        XCTAssertNil(policy.delay(forAttempt: 3))
    }

    func testAutomaticScrollAdaptsToObservedMovementAndConfidence() {
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.nextStep(
                from: 100,
                acceptedDeltaPixels: 100,
                viewportHeightPixels: 1_000,
                screenScale: 1,
                confidence: 0.94
            ),
            116
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.nextStep(
                from: 100,
                acceptedDeltaPixels: 280,
                viewportHeightPixels: 1_000,
                screenScale: 1,
                confidence: 0.82
            ),
            100
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.nextStep(
                from: 100,
                acceptedDeltaPixels: 280,
                viewportHeightPixels: 1_000,
                screenScale: 1,
                confidence: 0.61
            ),
            72
        )
    }

    func testAutomaticScrollStepAlwaysStaysInsideSafeRange() {
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.nextStep(
                from: 230,
                acceptedDeltaPixels: 80,
                viewportHeightPixels: 600,
                screenScale: 1,
                confidence: 0.98
            ),
            204
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.recoveryStep(from: 48, viewportHeightPoints: 600),
            LongScreenshotAutomaticScrollPolicy.minimumStep
        )
        XCTAssertEqual(LongScreenshotAutomaticScrollPolicy.initialStep(viewportHeightPoints: 1_000), 180)
    }

    func testAutomaticScrollRequiresPermissionAndOriginalApplication() {
        XCTAssertEqual(
            LongScreenshotAutomaticStartPolicy.decision(
                hasAccessibilityAccess: false,
                targetProcessIdentifier: 101,
                frontmostProcessIdentifier: 101
            ),
            .requestAccessibilityPermission
        )
        XCTAssertEqual(
            LongScreenshotAutomaticStartPolicy.decision(
                hasAccessibilityAccess: true,
                targetProcessIdentifier: 101,
                frontmostProcessIdentifier: 202
            ),
            .waitForTargetApplication
        )
        XCTAssertEqual(
            LongScreenshotAutomaticStartPolicy.decision(
                hasAccessibilityAccess: true,
                targetProcessIdentifier: 101,
                frontmostProcessIdentifier: 101
            ),
            .start
        )
    }
}

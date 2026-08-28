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

    func testAutomaticScrollAcceleratesOnlyAfterReliableAlignment() {
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.acceleratedStep(from: 44, confidence: 0.94),
            48
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.acceleratedStep(from: 44, confidence: 0.82),
            44
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.acceleratedStep(from: 44, confidence: 0.61),
            38
        )
    }

    func testAutomaticScrollStepAlwaysStaysInsideSafeRange() {
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.acceleratedStep(from: 56, confidence: 0.98),
            LongScreenshotAutomaticScrollPolicy.maximumStep
        )
        XCTAssertEqual(
            LongScreenshotAutomaticScrollPolicy.recoveryStep(from: 28),
            LongScreenshotAutomaticScrollPolicy.minimumStep
        )
    }
}

import XCTest
@testable import ShotMark

final class LongScreenshotQualityReportTests: XCTestCase {
    func testStoreKeepsOnlyMostRecentFiftyReports() throws {
        let fileURL = temporaryFileURL()
        let store = LongScreenshotQualityReportStore(fileURL: fileURL)

        for index in 0..<55 {
            store.record(makeReport(outputHeight: index))
        }

        let reports = store.reports()
        XCTAssertEqual(reports.count, 50)
        XCTAssertEqual(reports.first?.outputHeight, 5)
        XCTAssertEqual(reports.last?.outputHeight, 54)
    }

    func testCorruptReportFileDoesNotBlockNewDiagnostics() throws {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        let store = LongScreenshotQualityReportStore(fileURL: fileURL)

        XCTAssertTrue(store.reports().isEmpty)
        store.record(makeReport(outputHeight: 2_400))

        XCTAssertEqual(store.reports().map(\.outputHeight), [2_400])
    }

    func testSummaryExplainsPrivacyAndAggregatesQuality() {
        let store = LongScreenshotQualityReportStore(fileURL: temporaryFileURL())
        store.record(makeReport(outputHeight: 3_000, completion: .completedForSave))
        store.record(makeReport(outputHeight: 4_000, completion: .cancelled))

        let summary = store.summaryText(now: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(summary.contains("不包含截图、文字、应用名或文件路径"))
        XCTAssertTrue(summary.contains("最近会话：2/50"))
        XCTAssertTrue(summary.contains("完成：1"))
        XCTAssertTrue(summary.contains("取消：1"))
    }

    func testTrackerRecordsOutcomesAndFinishesOnlyOnce() {
        let store = LongScreenshotQualityReportStore(fileURL: temporaryFileURL())
        let tracker = LongScreenshotQualityTracker(
            viewportSize: CGSize(width: 1_200, height: 800),
            store: store,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        tracker.record(makeUpdate(outcome: .initialized, direction: .unresolved, confidence: 1))
        tracker.record(makeUpdate(outcome: .appended(deltaY: 600), direction: .downward, confidence: 0.9))
        tracker.record(makeUpdate(outcome: .ignoredAlignmentFailed, direction: .downward, confidence: 0.2))
        tracker.record(makeUpdate(outcome: .appended(deltaY: 500), direction: .upward, confidence: 0.8))
        tracker.recordRetry()
        tracker.recordAutomaticScrollingUsed()
        tracker.finish(
            completion: .completedForCopy,
            outputSize: CGSize(width: 1_200, height: 3_100),
            endedAt: Date(timeIntervalSince1970: 15)
        )
        tracker.finish(completion: .failed, endedAt: Date(timeIntervalSince1970: 20))

        let report = store.reports().first
        XCTAssertEqual(store.reports().count, 1)
        XCTAssertEqual(report?.completion, .completedForCopy)
        XCTAssertEqual(report?.durationSeconds, 5)
        XCTAssertEqual(report?.stitchAttempts, 4)
        XCTAssertEqual(report?.acceptedFrames, 3)
        XCTAssertEqual(report?.alignmentFailureFrames, 1)
        XCTAssertEqual(report?.retryCount, 1)
        XCTAssertEqual(report?.directionChangeCount, 1)
        XCTAssertEqual(report?.usedAutomaticScrolling, true)
    }

    func testRecoveryAdviceBecomesDirectionalAfterRepeatedFailures() {
        XCTAssertEqual(
            LongScreenshotRecoveryAdvice.controlStatus(
                consecutiveAlignmentFailures: 1,
                expectedDirection: .downward
            ),
            "暂未对齐，请继续缓慢滚动"
        )
        XCTAssertEqual(
            LongScreenshotRecoveryAdvice.controlStatus(
                consecutiveAlignmentFailures: 2,
                expectedDirection: .downward
            ),
            "重叠不足，向上回滚少许后慢滚"
        )
        XCTAssertEqual(
            LongScreenshotRecoveryAdvice.controlStatus(
                consecutiveAlignmentFailures: 3,
                expectedDirection: .upward
            ),
            "重叠不足，向下回滚少许后慢滚"
        )
    }

    private func makeUpdate(
        outcome: LongScreenshotStitchOutcome,
        direction: LongScreenshotStitchDirection,
        confidence: Double
    ) -> LongScreenshotStitchUpdate {
        LongScreenshotStitchUpdate(
            outcome: outcome,
            mergedImage: nil,
            acceptedFrameCount: 1,
            outputHeight: 800,
            direction: direction,
            confidence: confidence,
            maximumOutputHeight: 10_000
        )
    }

    private func makeReport(
        outputHeight: Int,
        completion: LongScreenshotSessionCompletion = .completedForSave
    ) -> LongScreenshotQualityReport {
        LongScreenshotQualityReport(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: TimeInterval(outputHeight)),
            durationSeconds: 2,
            completion: completion,
            viewportWidth: 1_000,
            viewportHeight: 800,
            outputWidth: 1_000,
            outputHeight: outputHeight,
            stitchAttempts: 4,
            acceptedFrames: 3,
            appendedFrames: 2,
            noMovementFrames: 0,
            coveredContentFrames: 0,
            alignmentFailureFrames: 1,
            retryCount: 1,
            directionChangeCount: 0,
            usedAutomaticScrolling: false,
            usedCompatibilityCapture: false,
            reachedCapacityLimit: false,
            averageConfidence: 0.75,
            minimumConfidence: 0.3
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotMarkQualityTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("reports.json")
    }
}

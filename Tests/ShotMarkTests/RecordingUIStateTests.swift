import XCTest
@testable import ShotMark

final class RecordingUIStateTests: XCTestCase {
    func testRecordingElapsedIncludesTimeBeforeResume() {
        let now = Date()
        let state = RecordingUIState.recording(
            startedAt: now.addingTimeInterval(-4.5),
            elapsedBeforeStart: 12
        )

        XCTAssertEqual(state.elapsed(at: now), 16.5, accuracy: 0.01)
    }

    func testPausedElapsedDoesNotAdvance() {
        let state = RecordingUIState.paused(elapsed: 8.25)

        XCTAssertEqual(state.elapsed(at: Date()), 8.25, accuracy: 0.001)
        XCTAssertEqual(state.elapsed(at: Date().addingTimeInterval(60)), 8.25, accuracy: 0.001)
        XCTAssertTrue(state.isPaused)
    }

    func testTransitionStatesKeepFrozenElapsedTime() {
        XCTAssertEqual(RecordingUIState.pausing(elapsed: 3).elapsed(), 3, accuracy: 0.001)
        XCTAssertEqual(RecordingUIState.resuming(elapsed: 7).elapsed(), 7, accuracy: 0.001)
    }
}

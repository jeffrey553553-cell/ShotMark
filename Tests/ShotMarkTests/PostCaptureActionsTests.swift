import Foundation
import XCTest
@testable import ShotMark

final class PostCaptureActionsTests: XCTestCase {
    func testDisabledCopyDoesNotInvokeClipboardWork() {
        var invocationCount = 0

        let result = PostCaptureActions.copyImageAfterSavingIfNeeded(
            pngData: Data("png".utf8),
            isEnabled: false
        ) { _ in
            invocationCount += 1
        }

        XCTAssertEqual(result, .notRequested)
        XCTAssertEqual(invocationCount, 0)
    }

    func testSuccessfulCopyProducesCombinedConfirmation() {
        let url = URL(fileURLWithPath: "/tmp/Screenshot.png")

        let result = PostCaptureActions.copyImageAfterSavingIfNeeded(
            pngData: Data("png".utf8),
            isEnabled: true
        ) { _ in }

        XCTAssertEqual(result, .copied)
        XCTAssertTrue(
            PostCaptureActions.saveConfirmation(for: url, followUpResult: result)
                .contains("已复制")
        )
    }

    func testCopyFailureDoesNotTurnSaveIntoFailure() {
        struct ClipboardError: Error {}
        let url = URL(fileURLWithPath: "/tmp/Screenshot.png")

        let result = PostCaptureActions.copyImageAfterSavingIfNeeded(
            pngData: Data("png".utf8),
            isEnabled: true
        ) { _ in
            throw ClipboardError()
        }
        let message = PostCaptureActions.saveConfirmation(
            for: url,
            followUpResult: result
        )

        XCTAssertEqual(result, .copyFailed)
        XCTAssertTrue(message.contains("已保存"))
        XCTAssertTrue(message.contains("复制失败"))
    }
}

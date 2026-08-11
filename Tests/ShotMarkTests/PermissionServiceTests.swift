import AVFoundation
import XCTest
@testable import ShotMark

final class PermissionServiceTests: XCTestCase {
    func testMicrophoneAuthorizationStatesRemainDistinct() {
        XCTAssertEqual(MicrophonePermissionState(.authorized), .authorized)
        XCTAssertEqual(MicrophonePermissionState(.notDetermined), .notDetermined)
        XCTAssertEqual(MicrophonePermissionState(.denied), .denied)
        XCTAssertEqual(MicrophonePermissionState(.restricted), .restricted)
    }

    func testOnlyAuthorizedMicrophoneStateIsGranted() {
        XCTAssertTrue(MicrophonePermissionState.authorized.isAuthorized)
        XCTAssertFalse(MicrophonePermissionState.notDetermined.isAuthorized)
        XCTAssertFalse(MicrophonePermissionState.denied.isAuthorized)
        XCTAssertFalse(MicrophonePermissionState.restricted.isAuthorized)
        XCTAssertFalse(MicrophonePermissionState.unknown.isAuthorized)
    }

    func testMicrophoneStatusTextExplainsTheNextUserAction() {
        XCTAssertEqual(MicrophonePermissionState.authorized.statusText, "已允许")
        XCTAssertEqual(MicrophonePermissionState.notDetermined.statusText, "尚未请求")
        XCTAssertEqual(MicrophonePermissionState.denied.statusText, "已拒绝")
        XCTAssertEqual(MicrophonePermissionState.restricted.statusText, "受系统限制")
    }
}

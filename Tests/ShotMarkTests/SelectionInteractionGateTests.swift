import XCTest
@testable import ShotMark

final class SelectionInteractionGateTests: XCTestCase {
    func testFirstOverlayOwnsInteractionForEntireSession() {
        let gate = SelectionInteractionGate()
        let first = NSObject()
        let second = NSObject()

        XCTAssertTrue(gate.claim(first))
        XCTAssertTrue(gate.claim(first))
        XCTAssertFalse(gate.claim(second))
        XCTAssertTrue(gate.isOwner(first))
        XCTAssertFalse(gate.isOwner(second))
    }

    func testResetAllowsAnotherOverlayToOwnNextSession() {
        let gate = SelectionInteractionGate()
        let first = NSObject()
        let second = NSObject()

        XCTAssertTrue(gate.claim(first))
        gate.reset()
        XCTAssertTrue(gate.claim(second))
        XCTAssertTrue(gate.isOwner(second))
    }
}

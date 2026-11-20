import XCTest
@testable import Clannad

final class PlayerScrollInputTests: XCTestCase {
    func testIndirectScrollUpSendsHistoryWheelStep() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: 22, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [1])
    }

    func testIndirectScrollDownSendsAdvanceWheelStep() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: -22, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [-1])
    }

    func testDirectSwipeUpSendsHistoryWheelStep() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: -22, isDirectTouch: true) { steps.append($0) }
        XCTAssertEqual(steps, [1])
    }

    func testDirectSwipeDownSendsAdvanceWheelStep() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: 22, isDirectTouch: true) { steps.append($0) }
        XCTAssertEqual(steps, [-1])
    }

    func testSmallScrollsAccumulateAndKeepRemainder() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: -10, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [])
        input.scroll(by: -40, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [-1, -1])
        input.scroll(by: -16, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [-1, -1, -1])
    }

    func testNewGestureDiscardsPreviousRemainder() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: -21, isDirectTouch: true) { steps.append($0) }
        input.reset()
        input.scroll(by: -1, isDirectTouch: true) { steps.append($0) }
        XCTAssertEqual(steps, [])
    }

    func testDirectionChangeCancelsUnconsumedMotion() {
        var input = PlayerScrollInput()
        var steps: [Int32] = []
        input.scroll(by: 15, isDirectTouch: false) { steps.append($0) }
        input.scroll(by: -15, isDirectTouch: false) { steps.append($0) }
        input.scroll(by: -22, isDirectTouch: false) { steps.append($0) }
        XCTAssertEqual(steps, [-1])
    }
}

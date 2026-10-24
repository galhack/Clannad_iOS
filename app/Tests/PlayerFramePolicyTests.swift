import XCTest
@testable import Clannad

final class PlayerFramePolicyTests: XCTestCase {
    func testNormalAndFairTemperatureUseThirtyFrames() {
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .nominal, lowPower: false), 30)
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .fair, lowPower: false), 30)
    }

    func testSeriousTemperatureAndLowPowerReduceCadence() {
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .serious, lowPower: false), 20)
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .nominal, lowPower: true), 20)
    }

    func testCriticalTemperatureUsesLowestCadenceEvenWithLowPower() {
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .critical, lowPower: false), 15)
        XCTAssertEqual(PlayerFramePolicy.framesPerSecond(thermalState: .critical, lowPower: true), 15)
    }
}

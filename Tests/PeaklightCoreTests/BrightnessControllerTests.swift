import XCTest
@testable import PeaklightCore

final class BrightnessControllerTests: XCTestCase {
    func testEightHundredNitPresetMapsToOnePointSixX() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)

        XCTAssertEqual(controller.state.desiredTargetNits, 800, accuracy: 0.001)
        XCTAssertEqual(controller.state.effectiveTargetNits, 800, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.6, accuracy: 0.001)
        XCTAssertTrue(controller.state.overlayEnabled)
    }

    func testNativePresetDisablesOverlay() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.native)

        XCTAssertEqual(controller.state.effectiveTargetNits, 500, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.0, accuracy: 0.001)
        XCTAssertFalse(controller.state.overlayEnabled)
    }

    func testBatteryPowerDoesNotReduceDefaultEightHundredNitCap() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.75))

        XCTAssertEqual(controller.state.effectiveTargetNits, 800, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.6, accuracy: 0.001)
        XCTAssertFalse(controller.state.capReasons.contains(.battery))
    }

    func testLowBatteryCapsBoostToSixHundredNits() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.20))

        XCTAssertEqual(controller.state.effectiveTargetNits, 600, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.2, accuracy: 0.001)
        XCTAssertTrue(controller.state.capReasons.contains(.lowBattery))
    }

    func testCriticalBatteryDisablesOverlay() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.10))

        XCTAssertEqual(controller.state.effectiveTargetNits, 500, accuracy: 0.001)
        XCTAssertFalse(controller.state.overlayEnabled)
        XCTAssertTrue(controller.state.capReasons.contains(.criticalBattery))
    }

    func testThermalPressureCapsBoostToSixHundredFiftyNits() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)
        controller.updateThermalPressure(.serious)

        XCTAssertEqual(controller.state.effectiveTargetNits, 650, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.3, accuracy: 0.001)
        XCTAssertTrue(controller.state.capReasons.contains(.thermal))
    }

    func testCriticalThermalPressureDisablesOverlay() {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)

        controller.setPreset(.eightHundred)
        controller.updateThermalPressure(.critical)

        XCTAssertEqual(controller.state.effectiveTargetNits, 500, accuracy: 0.001)
        XCTAssertFalse(controller.state.overlayEnabled)
    }

    func testEDRHeadroomCapsBoost() {
        let controller = BrightnessController(initialEDRHeadroom: 1.25)

        controller.setPreset(.eightHundred)

        XCTAssertEqual(controller.state.effectiveTargetNits, 625, accuracy: 0.001)
        XCTAssertEqual(controller.state.boostFactor, 1.25, accuracy: 0.001)
        XCTAssertTrue(controller.state.capReasons.contains(.edrHeadroom))
    }
}

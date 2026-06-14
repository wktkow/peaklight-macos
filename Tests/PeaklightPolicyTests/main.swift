import Darwin
import Foundation
import PeaklightCore

private struct CheckFailure {
    let message: String
}

private var failures: [CheckFailure] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(CheckFailure(message: message))
    }
}

private func checkEqual(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.001,
    _ message: String
) {
    if abs(actual - expected) > accuracy {
        failures.append(CheckFailure(message: "\(message): expected \(expected), got \(actual)"))
    }
}

private func runPolicyChecks() {
    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        checkEqual(controller.state.desiredTargetNits, 800, "800 nit preset stores desired target")
        checkEqual(controller.state.effectiveTargetNits, 800, "800 nit preset is effective with enough EDR")
        checkEqual(controller.state.boostFactor, 1.6, "800 nit preset maps to 1.6x")
        check(controller.state.overlayEnabled, "800 nit preset enables overlay")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.native)
        checkEqual(controller.state.effectiveTargetNits, 500, "native preset uses SDR reference white")
        checkEqual(controller.state.boostFactor, 1.0, "native preset maps to 1.0x")
        check(!controller.state.overlayEnabled, "native preset disables overlay")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.75))
        checkEqual(controller.state.effectiveTargetNits, 800, "battery power does not reduce the default 800 nit cap")
        checkEqual(controller.state.boostFactor, 1.6, "battery power keeps 800 nit preset at 1.6x")
        check(!controller.state.capReasons.contains(.battery), "battery cap reason is omitted when it does not lower the cap")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.20))
        checkEqual(controller.state.effectiveTargetNits, 600, "low battery limits boost to 600")
        checkEqual(controller.state.boostFactor, 1.2, "low battery cap maps to 1.2x")
        check(controller.state.capReasons.contains(.lowBattery), "low battery cap reason is reported")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        controller.updatePowerSource(.battery(level: 0.10))
        checkEqual(controller.state.effectiveTargetNits, 500, "critical battery disables boost")
        check(!controller.state.overlayEnabled, "critical battery disables overlay")
        check(controller.state.capReasons.contains(.criticalBattery), "critical battery cap reason is reported")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        controller.updateThermalPressure(.serious)
        checkEqual(controller.state.effectiveTargetNits, 650, "serious thermal pressure limits boost to 650")
        checkEqual(controller.state.boostFactor, 1.3, "serious thermal cap maps to 1.3x")
        check(controller.state.capReasons.contains(.thermal), "thermal cap reason is reported")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 2.0)
        controller.setPreset(.eightHundred)
        controller.updateThermalPressure(.critical)
        checkEqual(controller.state.effectiveTargetNits, 500, "critical thermal pressure disables boost")
        check(!controller.state.overlayEnabled, "critical thermal pressure disables overlay")
    }

    do {
        let controller = BrightnessController(initialEDRHeadroom: 1.25)
        controller.setPreset(.eightHundred)
        checkEqual(controller.state.effectiveTargetNits, 625, "EDR headroom caps effective target")
        checkEqual(controller.state.boostFactor, 1.25, "EDR headroom cap maps to available multiplier")
        check(controller.state.capReasons.contains(.edrHeadroom), "EDR cap reason is reported")
    }
}

runPolicyChecks()

if failures.isEmpty {
    print("All Peaklight policy checks passed.")
} else {
    for failure in failures {
        print("FAIL: \(failure.message)")
    }
    exit(1)
}

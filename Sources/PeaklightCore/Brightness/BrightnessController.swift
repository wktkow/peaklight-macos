import Foundation

public final class BrightnessController {
    public var onStateChange: ((BrightnessState) -> Void)?

    public private(set) var state: BrightnessState
    public private(set) var mode: BoostMode
    public private(set) var powerSource: PowerSourceState
    public private(set) var thermalPressure: ThermalPressure

    public var batteryCapsEnabled: Bool {
        didSet { recalculate(notify: true) }
    }

    public var thermalCapsEnabled: Bool {
        didSet { recalculate(notify: true) }
    }

    private let policy: BrightnessPolicy
    private var desiredTargetNits: Double
    private var availableEDRHeadroom: Double

    public init(
        policy: BrightnessPolicy = BrightnessPolicy(),
        initialDesiredTargetNits: Double? = nil,
        initialEDRHeadroom: Double = 1.0,
        mode: BoostMode = .clean,
        batteryCapsEnabled: Bool = true,
        thermalCapsEnabled: Bool = true,
        powerSource: PowerSourceState = .unknown,
        thermalPressure: ThermalPressure = .nominal
    ) {
        self.policy = policy
        self.desiredTargetNits = initialDesiredTargetNits ?? policy.sdrReferenceWhiteNits
        self.availableEDRHeadroom = max(1.0, initialEDRHeadroom)
        self.mode = mode
        self.batteryCapsEnabled = batteryCapsEnabled
        self.thermalCapsEnabled = thermalCapsEnabled
        self.powerSource = powerSource
        self.thermalPressure = thermalPressure
        self.state = BrightnessState(
            desiredTargetNits: policy.sdrReferenceWhiteNits,
            effectiveTargetNits: policy.sdrReferenceWhiteNits,
            boostFactor: 1.0,
            overlayEnabled: false,
            availableEDRHeadroom: max(1.0, initialEDRHeadroom),
            capReasons: []
        )
        recalculate(notify: false)
    }

    public func setMode(_ mode: BoostMode) {
        self.mode = mode
        recalculate(notify: true)
    }

    public func setPreset(_ preset: BoostPreset) {
        setDesiredTargetNits(preset.targetNits)
    }

    public func toggleDefaultBoost() {
        if state.overlayEnabled {
            setDesiredTargetNits(policy.sdrReferenceWhiteNits)
        } else {
            setDesiredTargetNits(policy.defaultTargetNits)
        }
    }

    public func increase(stepNits: Double = 50) {
        setDesiredTargetNits(desiredTargetNits + stepNits)
    }

    public func decrease(stepNits: Double = 50) {
        setDesiredTargetNits(desiredTargetNits - stepNits)
    }

    public func killSwitch() {
        setDesiredTargetNits(policy.sdrReferenceWhiteNits)
    }

    public func setDesiredTargetNits(_ targetNits: Double) {
        desiredTargetNits = min(
            max(targetNits, policy.sdrReferenceWhiteNits),
            policy.userMaximumTargetNits
        )
        recalculate(notify: true)
    }

    public func updateAvailableEDRHeadroom(_ headroom: Double) {
        availableEDRHeadroom = max(1.0, headroom)
        recalculate(notify: true)
    }

    public func updatePowerSource(_ powerSource: PowerSourceState) {
        self.powerSource = powerSource
        recalculate(notify: true)
    }

    public func updateThermalPressure(_ thermalPressure: ThermalPressure) {
        self.thermalPressure = thermalPressure
        recalculate(notify: true)
    }

    private func recalculate(notify: Bool) {
        var effectiveCap = policy.userMaximumTargetNits
        var reasons: [BrightnessCapReason] = []

        if batteryCapsEnabled, powerSource.isOnBattery {
            if policy.onBatteryCapNits < effectiveCap {
                effectiveCap = min(effectiveCap, policy.onBatteryCapNits)
                reasons.append(.battery)
            }

            if let level = powerSource.batteryLevel {
                if level <= policy.criticalBatteryThreshold {
                    effectiveCap = min(effectiveCap, policy.sdrReferenceWhiteNits)
                    reasons.append(.criticalBattery)
                } else if level <= policy.lowBatteryThreshold {
                    effectiveCap = min(effectiveCap, policy.lowBatteryCapNits)
                    reasons.append(.lowBattery)
                }
            }
        }

        if thermalCapsEnabled {
            switch thermalPressure {
            case .nominal, .fair:
                break
            case .serious:
                effectiveCap = min(effectiveCap, policy.thermalSeriousCapNits)
                reasons.append(.thermal)
            case .critical:
                effectiveCap = min(effectiveCap, policy.sdrReferenceWhiteNits)
                reasons.append(.thermal)
            }
        }

        let edrCap = policy.sdrReferenceWhiteNits * availableEDRHeadroom
        if edrCap < effectiveCap {
            effectiveCap = max(policy.sdrReferenceWhiteNits, edrCap)
            reasons.append(.edrHeadroom)
        }

        let effectiveTarget = min(desiredTargetNits, effectiveCap)
        let boostFactor = max(1.0, effectiveTarget / policy.sdrReferenceWhiteNits)
        let overlayEnabled = boostFactor > 1.0001

        var uniqueReasons: [BrightnessCapReason] = []
        for reason in reasons where !uniqueReasons.contains(reason) {
            uniqueReasons.append(reason)
        }

        state = BrightnessState(
            desiredTargetNits: desiredTargetNits,
            effectiveTargetNits: effectiveTarget,
            boostFactor: boostFactor,
            overlayEnabled: overlayEnabled,
            availableEDRHeadroom: availableEDRHeadroom,
            capReasons: uniqueReasons
        )

        if notify {
            onStateChange?(state)
        }
    }
}

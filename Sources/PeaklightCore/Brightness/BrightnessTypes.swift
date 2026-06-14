import Foundation

public enum BoostMode: String, CaseIterable, Equatable {
    case clean
    case shadowSafeExperimental

    public var displayName: String {
        switch self {
        case .clean:
            return "Clean Boost"
        case .shadowSafeExperimental:
            return "Shadow-Safe Boost (experimental)"
        }
    }
}

public enum BoostPreset: String, CaseIterable, Equatable {
    case native
    case sixHundred
    case sevenHundred
    case eightHundred

    public var targetNits: Double {
        switch self {
        case .native:
            return 500
        case .sixHundred:
            return 600
        case .sevenHundred:
            return 700
        case .eightHundred:
            return 800
        }
    }

    public var boostFactor: Double {
        targetNits / 500
    }

    public var displayName: String {
        switch self {
        case .native:
            return "Native SDR - 500 nits"
        case .sixHundred:
            return "600 nits - 1.2x"
        case .sevenHundred:
            return "700 nits - 1.4x"
        case .eightHundred:
            return "800 nits - 1.6x"
        }
    }
}

public enum PowerSourceState: Equatable {
    case externalPower
    case battery(level: Double?)
    case unknown

    public var isOnBattery: Bool {
        if case .battery = self {
            return true
        }
        return false
    }

    public var batteryLevel: Double? {
        if case let .battery(level) = self {
            return level
        }
        return nil
    }
}

public enum ThermalPressure: String, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

public enum BrightnessCapReason: String, Equatable {
    case battery
    case lowBattery
    case criticalBattery
    case thermal
    case edrHeadroom
    case userMaximum
}

public struct BrightnessPolicy: Equatable {
    public var sdrReferenceWhiteNits: Double
    public var defaultTargetNits: Double
    public var userMaximumTargetNits: Double
    public var onBatteryCapNits: Double
    public var lowBatteryCapNits: Double
    public var thermalSeriousCapNits: Double
    public var lowBatteryThreshold: Double
    public var criticalBatteryThreshold: Double

    public init(
        sdrReferenceWhiteNits: Double = 500,
        defaultTargetNits: Double = 800,
        userMaximumTargetNits: Double = 800,
        onBatteryCapNits: Double = 700,
        lowBatteryCapNits: Double = 600,
        thermalSeriousCapNits: Double = 650,
        lowBatteryThreshold: Double = 0.30,
        criticalBatteryThreshold: Double = 0.15
    ) {
        self.sdrReferenceWhiteNits = sdrReferenceWhiteNits
        self.defaultTargetNits = defaultTargetNits
        self.userMaximumTargetNits = userMaximumTargetNits
        self.onBatteryCapNits = onBatteryCapNits
        self.lowBatteryCapNits = lowBatteryCapNits
        self.thermalSeriousCapNits = thermalSeriousCapNits
        self.lowBatteryThreshold = lowBatteryThreshold
        self.criticalBatteryThreshold = criticalBatteryThreshold
    }
}

public struct BrightnessState: Equatable {
    public let desiredTargetNits: Double
    public let effectiveTargetNits: Double
    public let boostFactor: Double
    public let overlayEnabled: Bool
    public let availableEDRHeadroom: Double
    public let capReasons: [BrightnessCapReason]

    public var approximateDisplayText: String {
        if overlayEnabled {
            return "\(Int(effectiveTargetNits.rounded())) nits / \(String(format: "%.2fx", boostFactor))"
        }
        return "Native SDR"
    }
}

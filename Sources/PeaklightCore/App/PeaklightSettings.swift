import Foundation

public final class PeaklightSettings {
    private enum Key {
        static let desiredTargetNits = "desiredTargetNits"
        static let boostMode = "boostMode"
        static let batteryCapsEnabled = "batteryCapsEnabled"
        static let thermalCapsEnabled = "thermalCapsEnabled"
        static let keyboardControlEnabled = "keyboardControlEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    public var desiredTargetNits: Double {
        get { defaults.double(forKey: Key.desiredTargetNits) }
        set { defaults.set(newValue, forKey: Key.desiredTargetNits) }
    }

    public var boostMode: BoostMode {
        get {
            let rawValue = defaults.string(forKey: Key.boostMode) ?? BoostMode.clean.rawValue
            return BoostMode(rawValue: rawValue) ?? .clean
        }
        set { defaults.set(newValue.rawValue, forKey: Key.boostMode) }
    }

    public var batteryCapsEnabled: Bool {
        get { defaults.bool(forKey: Key.batteryCapsEnabled) }
        set { defaults.set(newValue, forKey: Key.batteryCapsEnabled) }
    }

    public var thermalCapsEnabled: Bool {
        get { defaults.bool(forKey: Key.thermalCapsEnabled) }
        set { defaults.set(newValue, forKey: Key.thermalCapsEnabled) }
    }

    public var keyboardControlEnabled: Bool {
        get { defaults.bool(forKey: Key.keyboardControlEnabled) }
        set { defaults.set(newValue, forKey: Key.keyboardControlEnabled) }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.desiredTargetNits: 500,
            Key.boostMode: BoostMode.clean.rawValue,
            Key.batteryCapsEnabled: true,
            Key.thermalCapsEnabled: true,
            Key.keyboardControlEnabled: false
        ])
    }
}

import Foundation

public final class PeaklightSettings {
  private enum Key {
    static let desiredTargetNits = "desiredTargetNits"
    static let boostMode = "boostMode"
    static let batteryCapsEnabled = "batteryCapsEnabled"
    static let thermalCapsEnabled = "thermalCapsEnabled"
    static let keyboardControlEnabled = "keyboardControlEnabled"
    // V3 deliberately does not revive either rejected prototype's enabled
    // state. Installation always starts this compositor path disabled.
    static let whiteDimmingEnabled = "compositorWhiteDimmingEnabledV3"
    static let whiteDimmingAmount = "compositorWhiteDimmingAmountV3"
  }

  private enum RetiredKey {
    static let legacyDefaultsSuite = "Peaklight"
    static let whiteDimmingWhiteLevel = "whiteDimmingWhiteLevel"
    static let lastSessionExitedCleanly = "lastSessionExitedCleanly"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    migrateRemovedWhiteDimmingSettings()
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

  public var whiteDimmingEnabled: Bool {
    get { defaults.bool(forKey: Key.whiteDimmingEnabled) }
    set { defaults.set(newValue, forKey: Key.whiteDimmingEnabled) }
  }

  public var whiteDimmingAmount: Double {
    get {
      WhiteDimmingPolicy.clampedAmount(
        defaults.double(forKey: Key.whiteDimmingAmount)
      )
    }
    set {
      defaults.set(
        WhiteDimmingPolicy.clampedAmount(newValue),
        forKey: Key.whiteDimmingAmount
      )
    }
  }

  private func registerDefaults() {
    defaults.register(defaults: [
      Key.desiredTargetNits: 500,
      Key.boostMode: BoostMode.clean.rawValue,
      Key.batteryCapsEnabled: true,
      Key.thermalCapsEnabled: true,
      Key.keyboardControlEnabled: false,
      Key.whiteDimmingEnabled: false,
      Key.whiteDimmingAmount: WhiteDimmingPolicy.defaultAmount,
    ])
  }

  private func migrateRemovedWhiteDimmingSettings() {
    resetRemovedWhiteDimmingSettings(in: defaults)

    guard defaults === UserDefaults.standard,
      let legacyDefaults = UserDefaults(
        suiteName: RetiredKey.legacyDefaultsSuite
      )
    else {
      return
    }
    resetRemovedWhiteDimmingSettings(in: legacyDefaults)
  }

  private func resetRemovedWhiteDimmingSettings(in domain: UserDefaults) {
    if domain.string(forKey: Key.boostMode) == "whiteDimming" {
      domain.set(BoostMode.clean.rawValue, forKey: Key.boostMode)
    }
    domain.removeObject(forKey: RetiredKey.whiteDimmingWhiteLevel)
    domain.removeObject(forKey: RetiredKey.lastSessionExitedCleanly)
  }
}

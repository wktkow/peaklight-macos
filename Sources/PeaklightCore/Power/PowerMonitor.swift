import Foundation
import IOKit.ps

public final class PowerMonitor {
    public var onChange: ((PowerSourceState, ThermalPressure) -> Void)?

    private var timer: Timer?
    private var lastPowerSource: PowerSourceState = .unknown
    private var lastThermalPressure: ThermalPressure = .nominal

    public init() {}

    public func start() {
        stop()
        publishIfChanged(force: true)

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.publishIfChanged(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    public func snapshot() -> (PowerSourceState, ThermalPressure) {
        (Self.currentPowerSource(), Self.currentThermalPressure())
    }

    @objc private func thermalStateDidChange() {
        publishIfChanged(force: false)
    }

    private func publishIfChanged(force: Bool) {
        let powerSource = Self.currentPowerSource()
        let thermalPressure = Self.currentThermalPressure()
        let changed = powerSource != lastPowerSource || thermalPressure != lastThermalPressure

        lastPowerSource = powerSource
        lastThermalPressure = thermalPressure

        if force || changed {
            onChange?(powerSource, thermalPressure)
        }
    }

    public static func currentPowerSource() -> PowerSourceState {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .unknown
        }

        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                continue
            }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            guard state == (kIOPSBatteryPowerValue as String) else {
                continue
            }

            let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let level: Double?
            if let current, let maximum, maximum > 0 {
                level = current / maximum
            } else {
                level = nil
            }
            return .battery(level: level)
        }

        return .externalPower
    }

    public static func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .serious
        }
    }
}

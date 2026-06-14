import AppKit
import Foundation

public final class PeaklightAppDelegate: NSObject, NSApplicationDelegate {
    private let settings: PeaklightSettings
    private let brightnessController: BrightnessController
    private let displayModel = DisplayModel()
    private let overlayEngine = OverlayEngine()
    private let powerMonitor = PowerMonitor()
    private let menuController = MenuController()

    private var keyboardController: KeyboardController?
    private var latestDisplays: [DisplaySnapshot] = []
    private var keyboardMessage: String?

    public override init() {
        let settings = PeaklightSettings()
        self.settings = settings
        self.brightnessController = BrightnessController(
            initialDesiredTargetNits: settings.desiredTargetNits,
            mode: settings.boostMode,
            batteryCapsEnabled: settings.batteryCapsEnabled,
            thermalCapsEnabled: settings.thermalCapsEnabled
        )
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        configureControllers()
        configureObservers()

        let powerSnapshot = powerMonitor.snapshot()
        brightnessController.updatePowerSource(powerSnapshot.0)
        brightnessController.updateThermalPressure(powerSnapshot.1)
        refreshDisplayState()

        powerMonitor.start()

        if settings.keyboardControlEnabled {
            setKeyboardControl(enabled: true, promptForAccessibility: false)
        }

        applyState()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        keyboardController?.stop()
        powerMonitor.stop()
        overlayEngine.disableAll()
    }

    private func configureControllers() {
        brightnessController.onStateChange = { [weak self] _ in
            MainThread.sync {
                self?.applyState()
            }
        }

        powerMonitor.onChange = { [weak self] powerSource, thermalPressure in
            MainThread.sync {
                self?.brightnessController.updatePowerSource(powerSource)
                self?.brightnessController.updateThermalPressure(thermalPressure)
            }
        }

        keyboardController = KeyboardController { [weak self] direction, phase in
            guard let self else {
                return false
            }
            return MainThread.sync {
                self.handleBrightnessKey(direction: direction, phase: phase)
            }
        }

        menuController.onSelectPreset = { [weak self] preset in
            self?.brightnessController.setPreset(preset)
        }
        menuController.onToggleMode = { [weak self] mode in
            self?.brightnessController.setMode(mode)
        }
        menuController.onToggleBatteryCaps = { [weak self] enabled in
            guard let self else { return }
            self.brightnessController.batteryCapsEnabled = enabled
            self.settings.batteryCapsEnabled = enabled
        }
        menuController.onToggleThermalCaps = { [weak self] enabled in
            guard let self else { return }
            self.brightnessController.thermalCapsEnabled = enabled
            self.settings.thermalCapsEnabled = enabled
        }
        menuController.onToggleKeyboardControl = { [weak self] enabled in
            self?.setKeyboardControl(enabled: enabled, promptForAccessibility: true)
        }
        menuController.onToggleDefaultBoost = { [weak self] in
            self?.brightnessController.toggleDefaultBoost()
        }
        menuController.onKillSwitch = { [weak self] in
            self?.brightnessController.killSwitch()
        }
        menuController.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func configureObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange() {
        refreshDisplayState()
        applyState()
    }

    @objc private func systemDidWake() {
        refreshDisplayState()
        applyState()
    }

    @objc private func screensDidWake() {
        refreshDisplayState()
        applyState()
    }

    private func refreshDisplayState() {
        latestDisplays = displayModel.currentDisplays()
        let headroom = latestDisplays
            .filter(\.isEDRCapable)
            .map(\.usableEDRHeadroom)
            .max() ?? 1.0
        brightnessController.updateAvailableEDRHeadroom(headroom)
    }

    private func applyState() {
        let state = brightnessController.state
        settings.desiredTargetNits = state.desiredTargetNits
        settings.boostMode = brightnessController.mode

        if state.overlayEnabled {
            overlayEngine.apply(boostFactor: state.boostFactor)
        } else {
            overlayEngine.disableAll()
        }

        menuController.update(
            state: state,
            mode: brightnessController.mode,
            displays: latestDisplays,
            batteryCapsEnabled: brightnessController.batteryCapsEnabled,
            thermalCapsEnabled: brightnessController.thermalCapsEnabled,
            keyboardControlEnabled: keyboardController?.isEnabled ?? false,
            keyboardMessage: keyboardMessage
        )
    }

    private func setKeyboardControl(enabled: Bool, promptForAccessibility: Bool) {
        guard let keyboardController else {
            return
        }

        if enabled {
            if keyboardController.start(promptForAccessibility: promptForAccessibility) {
                keyboardMessage = nil
                settings.keyboardControlEnabled = true
            } else {
                keyboardMessage = "Accessibility permission required for brightness keys"
                settings.keyboardControlEnabled = false
            }
        } else {
            keyboardController.stop()
            keyboardMessage = nil
            settings.keyboardControlEnabled = false
        }

        applyState()
    }

    private func handleBrightnessKey(
        direction: BrightnessKeyDirection,
        phase: BrightnessKeyPhase
    ) -> Bool {
        let state = brightnessController.state

        if phase == .up {
            return state.desiredTargetNits > 500
        }

        switch direction {
        case .up:
            guard state.availableEDRHeadroom > 1.0001 else {
                return false
            }
            brightnessController.increase()
            return true
        case .down:
            guard state.desiredTargetNits > 500 else {
                return false
            }
            brightnessController.decrease()
            return true
        }
    }
}

private enum MainThread {
    static func sync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}

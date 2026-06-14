import AppKit

public final class MenuController: NSObject {
    public var onSelectPreset: ((BoostPreset) -> Void)?
    public var onToggleMode: ((BoostMode) -> Void)?
    public var onToggleBatteryCaps: ((Bool) -> Void)?
    public var onToggleThermalCaps: ((Bool) -> Void)?
    public var onToggleKeyboardControl: ((Bool) -> Void)?
    public var onToggleDefaultBoost: (() -> Void)?
    public var onKillSwitch: (() -> Void)?
    public var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var latestState: BrightnessState?
    private var latestMode: BoostMode = .clean
    private var latestDisplays: [DisplaySnapshot] = []
    private var batteryCapsEnabled = true
    private var thermalCapsEnabled = true
    private var keyboardControlEnabled = false
    private var keyboardMessage: String?

    public override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = "Peaklight"
    }

    public func update(
        state: BrightnessState,
        mode: BoostMode,
        displays: [DisplaySnapshot],
        batteryCapsEnabled: Bool,
        thermalCapsEnabled: Bool,
        keyboardControlEnabled: Bool,
        keyboardMessage: String?
    ) {
        latestState = state
        latestMode = mode
        latestDisplays = displays
        self.batteryCapsEnabled = batteryCapsEnabled
        self.thermalCapsEnabled = thermalCapsEnabled
        self.keyboardControlEnabled = keyboardControlEnabled
        self.keyboardMessage = keyboardMessage

        statusItem.button?.title = state.overlayEnabled
            ? "Peaklight \(String(format: "%.1fx", state.boostFactor))"
            : "Peaklight"

        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Peaklight", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let latestState {
            let status = NSMenuItem(title: "Status: \(latestState.approximateDisplayText)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            if !latestState.capReasons.isEmpty {
                let caps = latestState.capReasons.map(\.displayName).joined(separator: ", ")
                let capItem = NSMenuItem(title: "Limited by: \(caps)", action: nil, keyEquivalent: "")
                capItem.isEnabled = false
                menu.addItem(capItem)
            }
        }

        let displayTitle = latestDisplays.isEmpty
            ? "Displays: none detected"
            : "Displays: \(latestDisplays.map(displayDescription).joined(separator: ", "))"
        let displayItem = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")
        displayItem.isEnabled = false
        menu.addItem(displayItem)
        menu.addItem(.separator())

        let toggleTitle: String
        if latestState?.overlayEnabled == true {
            toggleTitle = "Toggle 800 nit Boost Off"
        } else {
            toggleTitle = "Toggle 800 nit Boost On"
        }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleDefaultBoost), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        for preset in BoostPreset.allCases {
            let item = NSMenuItem(title: preset.displayName, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            if let latestState, abs(latestState.desiredTargetNits - preset.targetNits) < 0.5 {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for mode in BoostMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == latestMode ? .on : .off
            if mode == .shadowSafeExperimental {
                item.isEnabled = false
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addToggle(
            title: "Battery Caps",
            enabled: batteryCapsEnabled,
            action: #selector(toggleBatteryCaps(_:))
        )
        addToggle(
            title: "Thermal Caps",
            enabled: thermalCapsEnabled,
            action: #selector(toggleThermalCaps(_:))
        )
        addToggle(
            title: "Brightness Keys",
            enabled: keyboardControlEnabled,
            action: #selector(toggleKeyboardControl(_:))
        )

        if let keyboardMessage {
            let item = NSMenuItem(title: keyboardMessage, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let launchAtLogin = NSMenuItem(title: "Launch at Login: Off", action: nil, keyEquivalent: "")
        launchAtLogin.isEnabled = false
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        let killSwitch = NSMenuItem(title: "Kill Switch", action: #selector(runKillSwitch), keyEquivalent: "")
        killSwitch.target = self
        menu.addItem(killSwitch)

        let quit = NSMenuItem(title: "Quit Peaklight", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addToggle(title: String, enabled: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        menu.addItem(item)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let preset = BoostPreset(rawValue: rawValue)
        else {
            return
        }
        onSelectPreset?(preset)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = BoostMode(rawValue: rawValue)
        else {
            return
        }
        onToggleMode?(mode)
    }

    @objc private func toggleBatteryCaps(_ sender: NSMenuItem) {
        onToggleBatteryCaps?(sender.state != .on)
    }

    @objc private func toggleThermalCaps(_ sender: NSMenuItem) {
        onToggleThermalCaps?(sender.state != .on)
    }

    @objc private func toggleKeyboardControl(_ sender: NSMenuItem) {
        onToggleKeyboardControl?(sender.state != .on)
    }

    @objc private func toggleDefaultBoost() {
        onToggleDefaultBoost?()
    }

    @objc private func runKillSwitch() {
        onKillSwitch?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

private func displayDescription(_ display: DisplaySnapshot) -> String {
    guard display.isEDRCapable else {
        return "\(display.name) (SDR)"
    }

    return "\(display.name) (EDR \(String(format: "%.1fx", display.boostEDRHeadroom)))"
}

private extension BrightnessCapReason {
    var displayName: String {
        switch self {
        case .battery:
            return "battery"
        case .lowBattery:
            return "low battery"
        case .criticalBattery:
            return "critical battery"
        case .thermal:
            return "thermal pressure"
        case .edrHeadroom:
            return "EDR headroom"
        case .userMaximum:
            return "800 nit cap"
        }
    }
}

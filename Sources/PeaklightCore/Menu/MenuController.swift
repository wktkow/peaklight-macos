import AppKit

public final class MenuController: NSObject {
  public var onSelectPreset: ((BoostPreset) -> Void)?
  public var onToggleMode: ((BoostMode) -> Void)?
  public var onToggleBatteryCaps: ((Bool) -> Void)?
  public var onToggleThermalCaps: ((Bool) -> Void)?
  public var onToggleKeyboardControl: ((Bool) -> Void)?
  public var onToggleWhiteDimming: ((Bool) -> Void)?
  public var onWhiteDimmingAmountChanged: ((Double) -> Void)?
  public var onToggleDefaultBoost: (() -> Void)?
  public var onShowVersion: (() -> Void)?
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
  private var whiteDimmingEnabled = false
  private var whiteDimmingAmount = WhiteDimmingPolicy.defaultAmount
  private var whiteDimmingStatus: WhiteDimmingStatus = .off
  private var whiteDimmingSliderView: WhiteDimmingSliderView?

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
    keyboardMessage: String?,
    whiteDimmingEnabled: Bool,
    whiteDimmingAmount: Double,
    whiteDimmingStatus: WhiteDimmingStatus
  ) {
    latestState = state
    latestMode = mode
    latestDisplays = displays
    self.batteryCapsEnabled = batteryCapsEnabled
    self.thermalCapsEnabled = thermalCapsEnabled
    self.keyboardControlEnabled = keyboardControlEnabled
    self.keyboardMessage = keyboardMessage
    self.whiteDimmingEnabled = whiteDimmingEnabled
    self.whiteDimmingAmount = WhiteDimmingPolicy.clampedAmount(
      whiteDimmingAmount
    )
    self.whiteDimmingStatus = whiteDimmingStatus

    updateStatusItemTitle()

    rebuildMenu()
  }

  private func rebuildMenu() {
    menu.removeAllItems()

    let title = NSMenuItem(title: "Peaklight", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)

    let whiteDimming = NSMenuItem(
      title: "White dimming (RGB)",
      action: #selector(toggleWhiteDimming(_:)),
      keyEquivalent: ""
    )
    whiteDimming.target = self
    whiteDimming.state = whiteDimmingEnabled ? .on : .off
    whiteDimming.isEnabled = whiteDimmingIsAvailable
    menu.addItem(whiteDimming)

    let sliderView = WhiteDimmingSliderView(
      amount: whiteDimmingAmount,
      enabled: whiteDimmingEnabled && whiteDimmingIsAvailable,
      target: self,
      action: #selector(whiteDimmingSliderChanged(_:))
    )
    whiteDimmingSliderView = sliderView
    let sliderItem = NSMenuItem()
    sliderItem.view = sliderView
    menu.addItem(sliderItem)

    let dimmingStatus = NSMenuItem(
      title: whiteDimmingStatusText,
      action: nil,
      keyEquivalent: ""
    )
    dimmingStatus.isEnabled = false
    menu.addItem(dimmingStatus)

    let dimmingNote = NSMenuItem(
      title: "Neutral highlights only; maximum dimming 100%",
      action: nil,
      keyEquivalent: ""
    )
    dimmingNote.isEnabled = false
    menu.addItem(dimmingNote)
    menu.addItem(.separator())

    if let latestState {
      let status = NSMenuItem(
        title: "Status: \(latestState.approximateDisplayText)", action: nil, keyEquivalent: "")
      status.isEnabled = false
      menu.addItem(status)

      if !latestState.capReasons.isEmpty {
        let caps = latestState.capReasons.map(\.displayName).joined(separator: ", ")
        let capItem = NSMenuItem(title: "Limited by: \(caps)", action: nil, keyEquivalent: "")
        capItem.isEnabled = false
        menu.addItem(capItem)
      }
    }

    let displayTitle =
      latestDisplays.isEmpty
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
    let toggle = NSMenuItem(
      title: toggleTitle, action: #selector(toggleDefaultBoost), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)

    menu.addItem(.separator())

    for preset in BoostPreset.allCases {
      let item = NSMenuItem(
        title: preset.displayName, action: #selector(selectPreset(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = preset.rawValue
      if let latestState, abs(latestState.desiredTargetNits - preset.targetNits) < 0.5 {
        item.state = .on
      }
      menu.addItem(item)
    }

    menu.addItem(.separator())

    for mode in BoostMode.allCases {
      let item = NSMenuItem(
        title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
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
    let version = NSMenuItem(
      title: "Show Version", action: #selector(showVersion), keyEquivalent: "")
    version.target = self
    menu.addItem(version)

    let killSwitch = NSMenuItem(
      title: "Kill Switch", action: #selector(runKillSwitch), keyEquivalent: "")
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

  @objc private func toggleWhiteDimming(_ sender: NSMenuItem) {
    onToggleWhiteDimming?(sender.state != .on)
  }

  @objc private func whiteDimmingSliderChanged(_ sender: NSSlider) {
    whiteDimmingAmount = WhiteDimmingPolicy.clampedAmount(
      sender.doubleValue / 100
    )
    whiteDimmingSliderView?.updateAmount(whiteDimmingAmount)
    updateStatusItemTitle()
    onWhiteDimmingAmountChanged?(whiteDimmingAmount)
  }

  @objc private func toggleDefaultBoost() {
    onToggleDefaultBoost?()
  }

  @objc private func showVersion() {
    onShowVersion?()
  }

  @objc private func runKillSwitch() {
    onKillSwitch?()
  }

  @objc private func quit() {
    onQuit?()
  }

  private func updateStatusItemTitle() {
    if whiteDimmingEnabled {
      let percent = Int((whiteDimmingAmount * 100).rounded())
      switch whiteDimmingStatus {
      case .active:
        statusItem.button?.title = "Peaklight −\(percent)%"
      case .unavailable:
        statusItem.button?.title = "Peaklight Dim !"
      case .starting, .paused, .bypassed, .off:
        statusItem.button?.title = "Peaklight Dim"
      }
    } else if latestState?.overlayEnabled == true, let latestState {
      statusItem.button?.title = "Peaklight \(String(format: "%.1fx", latestState.boostFactor))"
    } else {
      statusItem.button?.title = "Peaklight"
    }
  }

  private var whiteDimmingStatusText: String {
    switch whiteDimmingStatus {
    case .off:
      return "White dimming: Off"
    case .bypassed:
      return "White dimming: 0% (no effect)"
    case .starting:
      return "White dimming: Updating compositor…"
    case .active(let displayCount):
      let suffix = displayCount == 1 ? "display" : "displays"
      return "White dimming: Active on \(displayCount) \(suffix)"
    case .paused:
      return "White dimming: Paused during display transition"
    case .unavailable(let message):
      return "White dimming unavailable: \(message)"
    }
  }

  private var whiteDimmingIsAvailable: Bool {
    if case .unavailable = whiteDimmingStatus {
      return false
    }
    return true
  }
}

private final class WhiteDimmingSliderView: NSView {
  private let valueLabel: NSTextField

  init(amount: Double, enabled: Bool, target: AnyObject, action: Selector) {
    let frame = NSRect(x: 0, y: 0, width: 320, height: 42)
    let label = NSTextField(labelWithString: "")
    self.valueLabel = label
    super.init(frame: frame)

    let slider = NSSlider(
      value: WhiteDimmingPolicy.clampedAmount(amount) * 100,
      minValue: 0,
      maxValue: WhiteDimmingPolicy.maximumAmount * 100,
      target: target,
      action: action
    )
    slider.frame = NSRect(x: 16, y: 10, width: 238, height: 22)
    slider.isContinuous = true
    slider.isEnabled = enabled
    slider.toolTip = "Compositor attenuation applied to neutral highlights"
    slider.setAccessibilityLabel("White dimming amount")
    addSubview(slider)

    label.frame = NSRect(x: 260, y: 11, width: 48, height: 20)
    label.alignment = .right
    label.textColor = enabled ? .labelColor : .disabledControlTextColor
    addSubview(label)
    updateAmount(amount)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateAmount(_ amount: Double) {
    valueLabel.stringValue = "\(Int((WhiteDimmingPolicy.clampedAmount(amount) * 100).rounded()))%"
  }
}

private func displayDescription(_ display: DisplaySnapshot) -> String {
  guard display.isEDRCapable else {
    return "\(display.name) (SDR)"
  }

  return "\(display.name) (EDR \(String(format: "%.1fx", display.boostEDRHeadroom)))"
}

extension BrightnessCapReason {
  fileprivate var displayName: String {
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

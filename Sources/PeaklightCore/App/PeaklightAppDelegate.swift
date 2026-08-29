import AppKit
import Foundation

@MainActor
public final class PeaklightAppDelegate: NSObject, NSApplicationDelegate {
  private let settings: PeaklightSettings
  private let brightnessController: BrightnessController
  private let displayModel = DisplayModel()
  private let overlayEngine = OverlayEngine()
  private let powerMonitor = PowerMonitor()
  private let menuController = MenuController()

  private var whiteDimmingControllerStorage: AnyObject?
  private var whiteDimmingStatus: WhiteDimmingStatus = .unavailable(
    "Requires the qualified macOS compositor build"
  )
  private var keyboardController: KeyboardController?
  private var latestDisplays: [DisplaySnapshot] = []
  private var keyboardMessage: String?
  private var aboutWindowController: AboutWindowController?

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
    configureWhiteDimmingController()
    configureObservers()

    let powerSnapshot = powerMonitor.snapshot()
    brightnessController.updatePowerSource(powerSnapshot.0)
    brightnessController.updateThermalPressure(powerSnapshot.1)
    refreshDisplayState()
    powerMonitor.start()

    if settings.keyboardControlEnabled {
      setKeyboardControl(enabled: true, promptForAccessibility: false)
    }
    if settings.whiteDimmingEnabled {
      brightnessController.killSwitch()
    }
    applyState()
  }

  public func applicationWillTerminate(_ notification: Notification) {
    if #available(macOS 15.0, *) {
      let controller = whiteDimmingControllerStorage as? WhiteDimmingBackdropController
      controller?.onStatusChange = nil
      controller?.shutdownImmediately()
    }
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
      guard let self else { return false }
      return MainThread.sync {
        self.handleBrightnessKey(direction: direction, phase: phase)
      }
    }

    menuController.onSelectPreset = { [weak self] preset in
      self?.selectPreset(preset)
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
    menuController.onToggleWhiteDimming = { [weak self] enabled in
      self?.setWhiteDimming(enabled: enabled)
    }
    menuController.onWhiteDimmingAmountChanged = { [weak self] amount in
      guard let self else { return }
      self.settings.whiteDimmingAmount = amount
      if #available(macOS 15.0, *) {
        (self.whiteDimmingControllerStorage
          as? WhiteDimmingBackdropController)?.setAmount(amount)
      }
    }
    menuController.onToggleDefaultBoost = { [weak self] in
      self?.toggleDefaultBoost()
    }
    menuController.onShowVersion = { [weak self] in
      self?.showVersionWindow()
    }
    menuController.onKillSwitch = { [weak self] in
      self?.runKillSwitch()
    }
    menuController.onQuit = {
      NSApp.terminate(nil)
    }
  }

  private func configureWhiteDimmingController() {
    guard #available(macOS 15.0, *),
      WhiteDimmingBackdropController.isSupported
    else {
      settings.whiteDimmingEnabled = false
      return
    }

    let controller = WhiteDimmingBackdropController(
      initialAmount: settings.whiteDimmingAmount
    )
    whiteDimmingControllerStorage = controller
    whiteDimmingStatus = controller.status
    controller.onStatusChange = { [weak self] status in
      guard let self else { return }
      self.whiteDimmingStatus = status
      self.applyState()
    }
  }

  private func configureObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    workspaceCenter.addObserver(
      self,
      selector: #selector(systemWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(screensDidSleep),
      name: NSWorkspace.screensDidSleepNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(screensDidWake),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(sessionDidResignActive),
      name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(sessionDidBecomeActive),
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(activeSpaceDidChange),
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
  }

  @objc private func screenParametersDidChange() {
    if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage as? WhiteDimmingBackdropController)?
        .screensDidChange(forceRestart: true)
    }
    refreshDisplayState()
    applyState()
  }

  @objc private func systemWillSleep() {
    if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage as? WhiteDimmingBackdropController)?
        .suspendContentEnvironment(for: .systemSleep)
    }
  }

  @objc private func systemDidWake() {
    if #available(macOS 15.0, *) {
      let controller =
        whiteDimmingControllerStorage
        as? WhiteDimmingBackdropController
      controller?.screensDidChange(forceRestart: true)
      controller?.resumeContentEnvironment(for: .systemSleep)
    }
    refreshDisplayState()
    applyState()
  }

  @objc private func screensDidSleep() {
    if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage as? WhiteDimmingBackdropController)?
        .suspendContentEnvironment(for: .screensSleep)
    }
  }

  @objc private func screensDidWake() {
    if #available(macOS 15.0, *) {
      let controller =
        whiteDimmingControllerStorage
        as? WhiteDimmingBackdropController
      controller?.screensDidChange(forceRestart: true)
      controller?.resumeContentEnvironment(for: .screensSleep)
    }
    refreshDisplayState()
    applyState()
  }

  @objc private func sessionDidResignActive() {
    if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage as? WhiteDimmingBackdropController)?
        .suspendContentEnvironment(for: .userSession)
    }
  }

  @objc private func sessionDidBecomeActive() {
    if #available(macOS 15.0, *) {
      let controller =
        whiteDimmingControllerStorage
        as? WhiteDimmingBackdropController
      controller?.screensDidChange(forceRestart: true)
      controller?.resumeContentEnvironment(for: .userSession)
    }
    refreshDisplayState()
    applyState()
  }

  @objc private func activeSpaceDidChange() {
    if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage as? WhiteDimmingBackdropController)?
        .contentEnvironmentDidChange()
    }
  }

  private func refreshDisplayState() {
    latestDisplays = displayModel.currentDisplays()
    let headroom =
      latestDisplays
      .filter(\.isEDRCapable)
      .map(\.boostEDRHeadroom)
      .max() ?? 1.0
    brightnessController.updateAvailableEDRHeadroom(headroom)
  }

  private func applyState() {
    let state = brightnessController.state
    settings.desiredTargetNits = state.desiredTargetNits
    settings.boostMode = brightnessController.mode

    if settings.whiteDimmingEnabled {
      overlayEngine.disableAll()
    } else if state.overlayEnabled {
      overlayEngine.apply(boostFactor: state.boostFactor)
    } else {
      overlayEngine.disableAll()
    }

    if #available(macOS 15.0, *),
      let controller = whiteDimmingControllerStorage
        as? WhiteDimmingBackdropController
    {
      controller.setEnabled(
        settings.whiteDimmingEnabled,
        amount: settings.whiteDimmingAmount
      )
      whiteDimmingStatus = controller.status
    }

    menuController.update(
      state: state,
      mode: brightnessController.mode,
      displays: latestDisplays,
      batteryCapsEnabled: brightnessController.batteryCapsEnabled,
      thermalCapsEnabled: brightnessController.thermalCapsEnabled,
      keyboardControlEnabled: keyboardController?.isEnabled ?? false,
      keyboardMessage: keyboardMessage,
      whiteDimmingEnabled: settings.whiteDimmingEnabled,
      whiteDimmingAmount: settings.whiteDimmingAmount,
      whiteDimmingStatus: whiteDimmingStatus
    )
  }

  private func setKeyboardControl(enabled: Bool, promptForAccessibility: Bool) {
    guard let keyboardController else { return }

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
      guard state.availableEDRHeadroom > 1.0001 else { return false }
      if settings.whiteDimmingEnabled {
        setWhiteDimming(enabled: false)
      }
      brightnessController.increase()
      return true
    case .down:
      guard state.desiredTargetNits > 500 else { return false }
      brightnessController.decrease()
      return true
    }
  }

  private func setWhiteDimming(enabled: Bool) {
    if enabled, whiteDimmingControllerStorage == nil {
      settings.whiteDimmingEnabled = false
      applyState()
      return
    }
    settings.whiteDimmingEnabled = enabled
    if enabled {
      overlayEngine.disableAll()
      if #available(macOS 15.0, *) {
        (whiteDimmingControllerStorage
          as? WhiteDimmingBackdropController)?.setEnabled(
            true,
            amount: settings.whiteDimmingAmount
          )
      }
      brightnessController.killSwitch()
    } else if #available(macOS 15.0, *) {
      (whiteDimmingControllerStorage
        as? WhiteDimmingBackdropController)?.setEnabled(
          false,
          amount: settings.whiteDimmingAmount
        )
    }
    applyState()
  }

  private func selectPreset(_ preset: BoostPreset) {
    if settings.whiteDimmingEnabled {
      setWhiteDimming(enabled: false)
    }
    brightnessController.setPreset(preset)
  }

  private func toggleDefaultBoost() {
    if settings.whiteDimmingEnabled {
      setWhiteDimming(enabled: false)
    }
    brightnessController.toggleDefaultBoost()
  }

  private func runKillSwitch() {
    if settings.whiteDimmingEnabled {
      setWhiteDimming(enabled: false)
    }
    brightnessController.killSwitch()
  }

  private func showVersionWindow() {
    let controller = AboutWindowController()
    aboutWindowController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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

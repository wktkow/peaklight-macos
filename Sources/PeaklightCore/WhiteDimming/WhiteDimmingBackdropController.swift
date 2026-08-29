import AppKit
import CoreGraphics
import Darwin
import Foundation
import PeaklightObjCShim
import QuartzCore

public enum WhiteDimmingStatus: Equatable {
  case off
  case bypassed
  case starting
  case active(displayCount: Int)
  case paused
  case unavailable(String)
}

/// Pure, bounded construction of the 3D mask sampled by Core Animation's
/// compositor-side `lut` filter. The image is flattened as N columns by N²
/// rows: red varies along X, then green, then blue along Y.
@available(macOS 15.0, *)
struct WhiteDimmingBackdropMaskLUT: Sendable, Equatable {
  static let defaultDimension = 64

  let dimension: Int
  let rgba8: Data

  init(dimension: Int = defaultDimension) {
    precondition((2...128).contains(dimension))
    self.dimension = dimension

    let voxelCount = dimension * dimension * dimension
    var bytes = [UInt8](repeating: 0, count: voxelCount * 4)
    let denominator = Double(dimension - 1)
    for blueIndex in 0..<dimension {
      let blue = Double(blueIndex) / denominator
      for greenIndex in 0..<dimension {
        let green = Double(greenIndex) / denominator
        for redIndex in 0..<dimension {
          let red = Double(redIndex) / denominator
          let encodedMask = UInt8(
            (Self.mask(red: red, green: green, blue: blue) * 255)
              .rounded()
          )
          let offset = Self.byteOffset(
            redIndex: redIndex,
            greenIndex: greenIndex,
            blueIndex: blueIndex,
            dimension: dimension
          )
          bytes[offset] = encodedMask
          bytes[offset + 1] = encodedMask
          bytes[offset + 2] = encodedMask
          bytes[offset + 3] = 255
        }
      }
    }
    rgba8 = Data(bytes)
  }

  static func mask(red: Double, green: Double, blue: Double) -> Double {
    WhiteDimmingPolicy.selectionMask(red: red, green: green, blue: blue)
  }

  func sample(
    redIndex: Int,
    greenIndex: Int,
    blueIndex: Int
  ) -> UInt8 {
    precondition((0..<dimension).contains(redIndex))
    precondition((0..<dimension).contains(greenIndex))
    precondition((0..<dimension).contains(blueIndex))
    return rgba8[
      Self.byteOffset(
        redIndex: redIndex,
        greenIndex: greenIndex,
        blueIndex: blueIndex,
        dimension: dimension
      )
    ]
  }

  func makeImage() -> CGImage? {
    guard let provider = CGDataProvider(data: rgba8 as CFData) else {
      return nil
    }
    // These are scalar lookup values, not display colors that should
    // receive an sRGB transfer function.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let alphaInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.last.rawValue
    )
    return CGImage(
      width: dimension,
      height: dimension * dimension,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: dimension * 4,
      space: colorSpace,
      bitmapInfo: [alphaInfo, .byteOrder32Big],
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  /// WindowServer source-over composition scales encoded Extended Display P3
  /// components. Encoding the requested linear-light endpoint makes a fully
  /// selected SDR white track the slider's target luminance.
  static func opacity(forAmount amount: Double) -> Float {
    let whiteLevel = Float(WhiteDimmingPolicy.whiteLevel(forAmount: amount))
    guard whiteLevel > 0 else { return 1 }
    guard whiteLevel < 1 else { return 0 }
    let encodedLevel =
      whiteLevel <= 0.003_130_8
      ? 12.92 * whiteLevel
      : 1.055 * pow(whiteLevel, 1 / 2.4) - 0.055
    return min(max(1 - encodedLevel, 0), 1)
  }

  private static func byteOffset(
    redIndex: Int,
    greenIndex: Int,
    blueIndex: Int,
    dimension: Int
  ) -> Int {
    ((blueIndex * dimension + greenIndex) * dimension + redIndex) * 4
  }
}

/// Runtime bridge to compositor implementation classes that are not declared
/// by public QuartzCore headers. Every lookup and KVC access fails closed.
@available(macOS 15.0, *)
enum WhiteDimmingBackdropRuntime {
  static let qualifiedKernelBuild = "25F84"

  private static let requiredBackdropSetters = [
    "setDisableFilterCache:",
    "setUpdateRate:",
    "setWindowServerAware:",
    "setGroupName:",
    "setScale:",
  ]

  private static let fallbackFramesPerSecond = 60

  static func capability(
    backdropLayerAvailable: Bool,
    sdrNormalizeFilterAvailable: Bool,
    lutFilterAvailable: Bool,
    luminanceToAlphaFilterAvailable: Bool
  ) -> Bool {
    backdropLayerAvailable
      && sdrNormalizeFilterAvailable
      && lutFilterAvailable
      && luminanceToAlphaFilterAvailable
  }

  /// The private graph is enabled only on the exact host build on which its
  /// behavior was qualified. Unknown OS revisions remain fail-open.
  static func buildIsQualified(
    isArm64: Bool,
    operatingSystemMajor: Int,
    operatingSystemMinor: Int,
    operatingSystemPatch: Int,
    kernelBuild: String?
  ) -> Bool {
    isArm64
      && operatingSystemMajor == 26
      && operatingSystemMinor == 5
      && operatingSystemPatch == 2
      && kernelBuild == qualifiedKernelBuild
  }

  static let isGraphSupported: Bool = {
    guard currentBuildIsQualified else { return false }
    return capability(
      backdropLayerAvailable: backdropLayerClassIsUsable,
      sdrNormalizeFilterAvailable: filterIsUsable(
        type: "sdrNormalize",
        requiredInputs: ["inputClamp", "inputClampPreserveHue"]
      ),
      lutFilterAvailable: filterIsUsable(
        type: "lut",
        requiredInputs: ["inputColorMap", "inputScale"]
      ),
      luminanceToAlphaFilterAvailable: filterIsUsable(
        type: "luminanceToAlpha",
        requiredInputs: ["inputPremultipliedValues"]
      )
    )
  }()

  /// `CABackdropLayer.updateRate` is an interval in seconds. Leaving its
  /// default value at zero lets WindowServer update a static backdrop only
  /// when its damage tracking happens to invalidate it, which can leave old
  /// pixels visible behind moving windows.
  static func compositorUpdateInterval(
    maximumFramesPerSecond: Int
  ) -> Double {
    let framesPerSecond =
      maximumFramesPerSecond > 0
      ? maximumFramesPerSecond
      : fallbackFramesPerSecond
    return 1 / Double(framesPerSecond)
  }

  static func makeBackdropLayer(
    colorMap: CGImage,
    maximumFramesPerSecond: Int
  ) -> CALayer? {
    guard isGraphSupported,
      let layerType = NSClassFromString("CABackdropLayer")
        as? CALayer.Type,
      let normalizeFilter = makeFilter(type: "sdrNormalize"),
      let lutFilter = makeFilter(type: "lut"),
      let luminanceFilter = makeFilter(type: "luminanceToAlpha")
    else {
      return nil
    }

    guard
      PeaklightTrySetValueForKey(
        normalizeFilter,
        true,
        "inputClamp"
      ),
      PeaklightTrySetValueForKey(
        normalizeFilter,
        true,
        "inputClampPreserveHue"
      ),
      PeaklightTrySetValueForKey(
        lutFilter,
        colorMap,
        "inputColorMap"
      ),
      PeaklightTrySetValueForKey(lutFilter, 1.0, "inputScale"),
      PeaklightTrySetValueForKey(
        luminanceFilter,
        false,
        "inputPremultipliedValues"
      )
    else {
      return nil
    }

    let updateInterval = compositorUpdateInterval(
      maximumFramesPerSecond: maximumFramesPerSecond
    )
    let layer = layerType.init()
    guard PeaklightTrySetValueForKey(layer, true, "disableFilterCache"),
      backdropFilterCacheIsDisabled(on: layer),
      PeaklightTrySetValueForKey(layer, updateInterval, "updateRate"),
      backdropUpdateInterval(
        on: layer,
        matches: updateInterval
      ),
      PeaklightTrySetValueForKey(layer, true, "windowServerAware"),
      PeaklightTrySetValueForKey(
        layer,
        "NSCGSWindowBehindWindowCaptureBackdropGroup",
        "groupName"
      ),
      PeaklightTrySetValueForKey(layer, 1.0, "scale")
    else {
      return nil
    }

    layer.filters = [normalizeFilter, lutFilter, luminanceFilter]
    layer.contentsFormat = .RGBA16Float
    layer.toneMapMode = .never
    if #available(macOS 26.0, *) {
      layer.preferredDynamicRange = .automatic
    } else {
      layer.wantsExtendedDynamicRangeContent = true
    }
    layer.isOpaque = false
    layer.backgroundColor = CGColor.clear
    layer.masksToBounds = true
    return layer
  }

  /// Backdrop caching can replay a stale WindowServer surface during motion,
  /// which is especially visible when the selected highlights approach black.
  /// Verify the private control after writing it so an incompatible runtime
  /// fails open instead of presenting cached frames.
  static func backdropFilterCacheIsDisabled(on layer: CALayer) -> Bool {
    guard
      let value = PeaklightTryValueForKey(layer, "disableFilterCache")
        as? NSNumber
    else {
      return false
    }
    return value.boolValue
  }

  /// Verify the private control after writing it so an incompatible runtime
  /// cannot silently fall back to the stale, damage-driven update behavior.
  static func backdropUpdateInterval(
    on layer: CALayer,
    matches expectedInterval: Double
  ) -> Bool {
    guard
      let value = PeaklightTryValueForKey(layer, "updateRate")
        as? NSNumber
    else {
      return false
    }
    let actualInterval = value.doubleValue
    return actualInterval.isFinite
      && abs(actualInterval - expectedInterval) <= 0.000_000_001
  }

  private static var currentBuildIsQualified: Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
      let isArm64 = true
    #else
      let isArm64 = false
    #endif
    return buildIsQualified(
      isArm64: isArm64,
      operatingSystemMajor: version.majorVersion,
      operatingSystemMinor: version.minorVersion,
      operatingSystemPatch: version.patchVersion,
      kernelBuild: systemString(named: "kern.osversion")
    )
  }

  private static var backdropLayerClassIsUsable: Bool {
    guard let layerClass = NSClassFromString("CABackdropLayer"),
      layerClass is CALayer.Type
    else {
      return false
    }
    return requiredBackdropSetters.allSatisfy { selectorName in
      class_getInstanceMethod(
        layerClass,
        NSSelectorFromString(selectorName)
      ) != nil
    }
  }

  private static func filterIsUsable(
    type: String,
    requiredInputs: Set<String>
  ) -> Bool {
    guard let filter = makeFilter(type: type),
      let inputKeys = PeaklightTryValueForKey(filter, "inputKeys")
        as? [String]
    else {
      return false
    }
    return requiredInputs.isSubset(of: Set(inputKeys))
  }

  private static func makeFilter(type: String) -> NSObject? {
    PeaklightTryCreateCAFilter(type) as? NSObject
  }

  private static func systemString(named name: String) -> String? {
    var byteCount = 0
    guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0,
      byteCount > 1
    else {
      return nil
    }
    var bytes = [CChar](repeating: 0, count: byteCount)
    guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else {
      return nil
    }
    return String(cString: bytes)
  }
}

@available(macOS 15.0, *)
enum WhiteDimmingEnvironmentSuspensionReason: Hashable {
  case systemSleep
  case screensSleep
  case userSession
}

/// Compositor-synchronous white dimming. WindowServer samples its current
/// backdrop while composing the screen; Peaklight never captures or replays a
/// desktop frame and therefore needs no Screen Recording permission.
@available(macOS 15.0, *)
@MainActor
public final class WhiteDimmingBackdropController {
  public enum State: Sendable, Equatable {
    case unavailable(reason: String)
    case disabled
    case bypassed
    case settling
    case running(displayCount: Int)
    case suspended
    case failed(reason: String)
  }

  public var onStatusChange: ((WhiteDimmingStatus) -> Void)?
  public private(set) var state: State

  public var status: WhiteDimmingStatus {
    switch state {
    case .disabled:
      return .off
    case .bypassed:
      return .bypassed
    case .settling:
      return .starting
    case .running(let displayCount):
      return .active(displayCount: displayCount)
    case .suspended:
      return .paused
    case .unavailable(let reason), .failed(let reason):
      return .unavailable(reason)
    }
  }

  public static var isSupported: Bool {
    WhiteDimmingBackdropRuntime.isGraphSupported
  }

  private static let noEffectThreshold = 0.000_001
  private static let environmentSettleNanoseconds: UInt64 = 300_000_000

  private var desiredEnabled = false
  private var amount: Double
  private var sessions: [WhiteDimmingBackdropSession] = []
  private var suspensionReasons = Set<WhiteDimmingEnvironmentSuspensionReason>()
  private var observedTopology: [WhiteDimmingBackdropTopologyEntry]
  private var reconcileGeneration: UInt64 = 0
  private var settleTask: Task<Void, Never>?
  private var colorMap: CGImage?
  private var isShuttingDown = false

  var activeSessionCountForTesting: Int { sessions.count }
  var hasPendingSettledRebuildForTesting: Bool { settleTask != nil }

  public init(initialAmount: Double = WhiteDimmingPolicy.defaultAmount) {
    amount = WhiteDimmingPolicy.clampedAmount(initialAmount)
    observedTopology = Self.topology()
    state =
      Self.isSupported
      ? .disabled
      : .unavailable(
        reason: "Compositor white dimming is unavailable on this macOS build"
      )
  }

  public func setEnabled(_ enabled: Bool, amount: Double) {
    guard !isShuttingDown else { return }
    desiredEnabled = enabled
    self.amount = WhiteDimmingPolicy.clampedAmount(amount)
    reconcileImmediately()
  }

  public func setAmount(_ amount: Double) {
    guard !isShuttingDown else { return }
    let priorWasBypassed = self.amount <= Self.noEffectThreshold
    self.amount = WhiteDimmingPolicy.clampedAmount(amount)
    let isBypassed = self.amount <= Self.noEffectThreshold

    guard Self.isSupported else {
      destroySessions()
      transition(
        to: .unavailable(
          reason: "Compositor white dimming is unavailable on this macOS build"
        )
      )
      return
    }
    guard desiredEnabled else {
      transition(to: .disabled)
      return
    }
    guard priorWasBypassed == isBypassed else {
      reconcileImmediately()
      return
    }
    guard !isBypassed else {
      transition(to: .bypassed)
      return
    }
    applyOpacity()
  }

  public func screensDidChange(forceRestart: Bool = false) {
    guard !isShuttingDown else { return }
    let latest = Self.topology()
    guard forceRestart || latest != observedTopology else { return }
    observedTopology = latest
    retireCurrentEnvironment()
    scheduleSettledRebuild()
  }

  public func contentEnvironmentDidChange() {
    guard !isShuttingDown, shouldRun else { return }
    retireCurrentEnvironment()
    scheduleSettledRebuild()
  }

  func suspendContentEnvironment(
    for reason: WhiteDimmingEnvironmentSuspensionReason
  ) {
    guard !isShuttingDown else { return }
    suspensionReasons.insert(reason)
    suspendNow()
  }

  func resumeContentEnvironment(
    for reason: WhiteDimmingEnvironmentSuspensionReason
  ) {
    guard !isShuttingDown else { return }
    suspensionReasons.remove(reason)
    resumeAfterSettleIfPossible()
  }

  public func shutdownImmediately() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    desiredEnabled = false
    cancelSettledRebuild()
    destroySessions()
    transition(to: .disabled)
  }

  private var shouldRun: Bool {
    desiredEnabled
      && amount > Self.noEffectThreshold
      && suspensionReasons.isEmpty
      && !isShuttingDown
  }

  private func reconcileImmediately() {
    guard Self.isSupported else {
      cancelSettledRebuild()
      destroySessions()
      transition(
        to: .unavailable(
          reason: "Compositor white dimming is unavailable on this macOS build"
        )
      )
      return
    }

    // A redundant app-level reconciliation during a Space or wake event
    // must not erase the WindowServer settle delay.
    if settleTask != nil, shouldRun {
      return
    }
    cancelSettledRebuild()

    guard desiredEnabled else {
      destroySessions()
      transition(to: .disabled)
      return
    }
    guard amount > Self.noEffectThreshold else {
      destroySessions()
      transition(to: .bypassed)
      return
    }
    guard suspensionReasons.isEmpty else {
      orderOutSessions()
      transition(to: .suspended)
      return
    }
    if sessions.isEmpty {
      rebuildSessions()
    } else {
      applyOpacity()
      transition(to: .running(displayCount: sessions.count))
    }
  }

  private func suspendNow() {
    cancelSettledRebuild()
    orderOutSessions()
    if desiredEnabled, amount > Self.noEffectThreshold {
      transition(to: .suspended)
    }
  }

  private func resumeAfterSettleIfPossible() {
    guard suspensionReasons.isEmpty else { return }
    guard shouldRun else {
      reconcileImmediately()
      return
    }
    retireCurrentEnvironment()
    scheduleSettledRebuild()
  }

  private func retireCurrentEnvironment() {
    cancelSettledRebuild()
    destroySessions()
    if shouldRun {
      transition(to: .settling)
    }
  }

  private func scheduleSettledRebuild() {
    guard shouldRun else {
      reconcileImmediately()
      return
    }
    cancelSettledRebuild()
    reconcileGeneration = Self.successor(of: reconcileGeneration)
    let expectedGeneration = reconcileGeneration
    transition(to: .settling)
    settleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(
        nanoseconds: Self.environmentSettleNanoseconds
      )
      guard !Task.isCancelled,
        let self,
        self.reconcileGeneration == expectedGeneration
      else {
        return
      }
      self.settleTask = nil
      self.observedTopology = Self.topology()
      self.reconcileImmediately()
    }
  }

  private func cancelSettledRebuild() {
    reconcileGeneration = Self.successor(of: reconcileGeneration)
    settleTask?.cancel()
    settleTask = nil
  }

  private func rebuildSessions() {
    destroySessions()
    let screens = NSScreen.screens
    guard !screens.isEmpty else {
      transition(to: .failed(reason: "No active display was available"))
      return
    }
    if colorMap == nil {
      colorMap = WhiteDimmingBackdropMaskLUT().makeImage()
    }
    guard let colorMap else {
      transition(to: .failed(reason: "Could not construct white-dimming LUT"))
      return
    }

    var replacements: [WhiteDimmingBackdropSession] = []
    replacements.reserveCapacity(screens.count)
    for screen in screens {
      guard
        let output = WhiteDimmingBackdropOutputWindow(
          screen: screen,
          colorMap: colorMap,
          amount: amount
        )
      else {
        for replacement in replacements {
          replacement.output.close()
        }
        transition(
          to: .failed(
            reason: "Could not construct compositor white dimming"
          )
        )
        return
      }
      replacements.append(
        WhiteDimmingBackdropSession(
          displayID: DisplayModel.screenID(for: screen),
          output: output
        )
      )
    }
    sessions = replacements
    observedTopology = Self.topology()
    transition(to: .running(displayCount: sessions.count))
  }

  private func applyOpacity() {
    let opacity = WhiteDimmingBackdropMaskLUT.opacity(forAmount: amount)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for session in sessions {
      session.output.backdropLayer.opacity = opacity
    }
    CATransaction.commit()
  }

  private func orderOutSessions() {
    for session in sessions {
      session.output.orderOut()
    }
  }

  private func destroySessions() {
    let retired = sessions
    sessions.removeAll(keepingCapacity: true)
    for session in retired {
      session.output.close()
    }
  }

  private func transition(to newState: State) {
    guard state != newState else { return }
    state = newState
    onStatusChange?(status)
  }

  private static func topology() -> [WhiteDimmingBackdropTopologyEntry] {
    NSScreen.screens.map { screen in
      WhiteDimmingBackdropTopologyEntry(
        displayID: DisplayModel.screenID(for: screen),
        frame: screen.frame,
        backingScaleFactor: screen.backingScaleFactor,
        maximumFramesPerSecond: screen.maximumFramesPerSecond
      )
    }.sorted {
      if $0.displayID == $1.displayID {
        return $0.frame.minX < $1.frame.minX
      }
      return $0.displayID < $1.displayID
    }
  }

  private static func successor(of value: UInt64) -> UInt64 {
    value == .max ? .max : value + 1
  }
}

@available(macOS 15.0, *)
private struct WhiteDimmingBackdropTopologyEntry: Equatable {
  let displayID: CGDirectDisplayID
  let frame: CGRect
  let backingScaleFactor: CGFloat
  let maximumFramesPerSecond: Int
}

@available(macOS 15.0, *)
@MainActor
private final class WhiteDimmingBackdropSession {
  let displayID: CGDirectDisplayID
  let output: WhiteDimmingBackdropOutputWindow

  init(
    displayID: CGDirectDisplayID,
    output: WhiteDimmingBackdropOutputWindow
  ) {
    self.displayID = displayID
    self.output = output
  }
}

@available(macOS 15.0, *)
@MainActor
private final class WhiteDimmingBackdropOutputWindow {
  let window: NSWindow
  let backdropLayer: CALayer

  init?(screen: NSScreen, colorMap: CGImage, amount: Double) {
    guard
      let backdropLayer = WhiteDimmingBackdropRuntime.makeBackdropLayer(
        colorMap: colorMap,
        maximumFramesPerSecond: screen.maximumFramesPerSecond
      )
    else {
      return nil
    }

    let frame = screen.frame
    backdropLayer.frame = CGRect(origin: .zero, size: frame.size)
    backdropLayer.contentsScale = screen.backingScaleFactor
    backdropLayer.autoresizingMask = [
      .layerWidthSizable,
      .layerHeightSizable,
    ]
    backdropLayer.opacity = WhiteDimmingBackdropMaskLUT.opacity(
      forAmount: amount
    )

    let view = WhiteDimmingBackdropView(
      frame: NSRect(origin: .zero, size: frame.size),
      backdropLayer: backdropLayer
    )
    view.autoresizingMask = [.width, .height]

    let window = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    window.level = OverlayWindowPolicy.whiteDimmingLevel
    window.collectionBehavior = OverlayWindowPolicy.whiteDimmingCollectionBehavior
    window.isOpaque = false
    window.backgroundColor = .clear
    window.alphaValue = 1
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.acceptsMouseMovedEvents = false
    window.hidesOnDeactivate = false
    window.canHide = false
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.tabbingMode = .disallowed
    window.becomesKeyOnlyIfNeeded = true
    window.contentView = view
    window.orderFrontRegardless()

    self.window = window
    self.backdropLayer = backdropLayer
  }

  func orderOut() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdropLayer.opacity = 0
    CATransaction.commit()
    window.orderOut(nil)
  }

  func close() {
    orderOut()
    backdropLayer.filters = nil
    backdropLayer.removeFromSuperlayer()
    window.contentView = nil
    window.close()
  }
}

@available(macOS 15.0, *)
private final class WhiteDimmingBackdropView: NSView {
  init(frame: NSRect, backdropLayer: CALayer) {
    super.init(frame: frame)
    wantsLayer = true

    let rootLayer = CALayer()
    rootLayer.frame = bounds
    rootLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    rootLayer.isOpaque = false
    rootLayer.backgroundColor = CGColor.clear
    layer = rootLayer
    rootLayer.addSublayer(backdropLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

import AppKit
import Foundation
import XCTest

@testable import PeaklightCore

@available(macOS 15.0, *)
final class WhiteDimmingPolicyTests: XCTestCase {
  func testAmountCoversTheFullZeroToOneRange() {
    XCTAssertEqual(WhiteDimmingPolicy.clampedAmount(-1), 0)
    XCTAssertEqual(WhiteDimmingPolicy.clampedAmount(0.25), 0.25)
    XCTAssertEqual(WhiteDimmingPolicy.clampedAmount(1), 1)
    XCTAssertEqual(WhiteDimmingPolicy.clampedAmount(2), 1)
    XCTAssertEqual(WhiteDimmingPolicy.clampedAmount(.nan), 0.5)
  }

  func testPureWhiteIsTransferCalibratedAtHalfAndReachesBlackAtMaximum() {
    XCTAssertEqual(
      WhiteDimmingPolicy.gain(red: 1, green: 1, blue: 1, amount: 0.5),
      0.5,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      WhiteDimmingPolicy.gain(red: 1, green: 1, blue: 1, amount: 1),
      0,
      accuracy: 0
    )
    XCTAssertEqual(
      WhiteDimmingBackdropMaskLUT.opacity(forAmount: 1),
      1,
      accuracy: 0
    )
    XCTAssertEqual(
      Self.decodeSRGB(
        1
          - Double(
            WhiteDimmingBackdropMaskLUT.opacity(forAmount: 0.5)
          )
      ),
      0.5,
      accuracy: 0.000_001
    )
  }

  func testSaturatedColorsAndMidGrayArePassedThrough() {
    let unchanged: [(Double, Double, Double)] = [
      (0, 0, 1),
      (1, 0, 0),
      (0, 1, 1),
      (1, 0.55, 0),
      (0.7, 0.7, 0.7),
      (0, 0, 0),
    ]
    for color in unchanged {
      XCTAssertEqual(
        WhiteDimmingPolicy.selectionMask(
          red: color.0,
          green: color.1,
          blue: color.2
        ),
        0,
        accuracy: 0.000_001
      )
      XCTAssertEqual(
        WhiteDimmingPolicy.gain(
          red: color.0,
          green: color.1,
          blue: color.2,
          amount: 1
        ),
        1,
        accuracy: 0.000_001
      )
    }
  }

  func testHueNormalizedHDRSelectsNeutralWhiteButNotHDRColor() {
    XCTAssertEqual(
      WhiteDimmingPolicy.selectionMask(red: 4, green: 4, blue: 4),
      1,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      WhiteDimmingPolicy.selectionMask(red: 4, green: 2, blue: 8),
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      WhiteDimmingPolicy.selectionMask(red: 0, green: 0, blue: 8),
      0,
      accuracy: 0.000_001
    )
  }

  func testMaskCubeHasExpectedLayoutAndSymmetry() throws {
    let lut = WhiteDimmingBackdropMaskLUT(dimension: 17)
    XCTAssertEqual(lut.rgba8.count, 17 * 17 * 17 * 4)
    XCTAssertEqual(lut.sample(redIndex: 16, greenIndex: 16, blueIndex: 16), 255)
    XCTAssertEqual(lut.sample(redIndex: 0, greenIndex: 0, blueIndex: 16), 0)
    XCTAssertEqual(
      lut.sample(redIndex: 15, greenIndex: 16, blueIndex: 16),
      lut.sample(redIndex: 16, greenIndex: 15, blueIndex: 16)
    )

    let image = try XCTUnwrap(lut.makeImage())
    XCTAssertEqual(image.width, 17)
    XCTAssertEqual(image.height, 17 * 17)
    XCTAssertEqual(image.bitsPerPixel, 32)
    XCTAssertEqual(image.dataProvider?.data as Data?, lut.rgba8)
  }

  func testRuntimeCapabilityRequiresTheCompleteGraph() {
    XCTAssertTrue(
      WhiteDimmingBackdropRuntime.capability(
        backdropLayerAvailable: true,
        sdrNormalizeFilterAvailable: true,
        lutFilterAvailable: true,
        luminanceToAlphaFilterAvailable: true
      )
    )
    XCTAssertFalse(
      WhiteDimmingBackdropRuntime.capability(
        backdropLayerAvailable: true,
        sdrNormalizeFilterAvailable: false,
        lutFilterAvailable: true,
        luminanceToAlphaFilterAvailable: true
      )
    )
  }

  func testRuntimeBuildAllowlistIsExact() {
    XCTAssertTrue(
      WhiteDimmingBackdropRuntime.buildIsQualified(
        isArm64: true,
        operatingSystemMajor: 26,
        operatingSystemMinor: 5,
        operatingSystemPatch: 2,
        kernelBuild: "25F84"
      )
    )
    XCTAssertFalse(
      WhiteDimmingBackdropRuntime.buildIsQualified(
        isArm64: true,
        operatingSystemMajor: 26,
        operatingSystemMinor: 5,
        operatingSystemPatch: 3,
        kernelBuild: "25F84"
      )
    )
  }

  @MainActor
  func testQualifiedHostExposesTheCompleteCompositorGraph() throws {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard
      version.majorVersion == 26,
      version.minorVersion == 5,
      version.patchVersion == 2
    else {
      throw XCTSkip("The private compositor graph is qualified only on macOS 26.5.2")
    }

    XCTAssertTrue(WhiteDimmingBackdropRuntime.isGraphSupported)
    let colorMap = try XCTUnwrap(WhiteDimmingBackdropMaskLUT().makeImage())
    let backdropLayer = try XCTUnwrap(
      WhiteDimmingBackdropRuntime.makeBackdropLayer(colorMap: colorMap)
    )
    XCTAssertTrue(
      WhiteDimmingBackdropRuntime.backdropFilterCacheIsDisabled(
        on: backdropLayer
      )
    )
    backdropLayer.filters = nil

    let controller = WhiteDimmingBackdropController(initialAmount: 0.5)
    XCTAssertEqual(controller.state, .disabled)
    XCTAssertEqual(controller.activeSessionCountForTesting, 0)
    controller.shutdownImmediately()
  }

  func testSettingsStartDisabledAndPersistOnlyClampedAmount() {
    let suiteName = "WhiteDimmingPolicyTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create isolated defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = PeaklightSettings(defaults: defaults)
    XCTAssertFalse(settings.whiteDimmingEnabled)
    XCTAssertEqual(settings.whiteDimmingAmount, 0.5)

    settings.whiteDimmingEnabled = true
    settings.whiteDimmingAmount = 2
    XCTAssertTrue(settings.whiteDimmingEnabled)
    XCTAssertEqual(settings.whiteDimmingAmount, 1)
  }

  func testMissionControlAndMenuBarWindowPolicy() {
    let behavior = OverlayWindowPolicy.whiteDimmingCollectionBehavior
    XCTAssertTrue(behavior.contains(.transient))
    XCTAssertTrue(behavior.contains(.ignoresCycle))
    XCTAssertFalse(behavior.contains(.stationary))

    let level = OverlayWindowPolicy.whiteDimmingLevel.rawValue
    XCTAssertGreaterThan(level, NSWindow.Level.statusBar.rawValue)
    XCTAssertLessThan(level, NSWindow.Level.popUpMenu.rawValue)
  }

  private static func decodeSRGB(_ encoded: Double) -> Double {
    encoded <= 0.04045
      ? encoded / 12.92
      : pow((encoded + 0.055) / 1.055, 2.4)
  }
}

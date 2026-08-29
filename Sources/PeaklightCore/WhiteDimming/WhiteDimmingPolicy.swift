import Foundation

/// Shared, pure policy for compositor-side neutral-highlight attenuation.
public enum WhiteDimmingPolicy {
  /// At the maximum, a fully selected white reaches black. The saved default
  /// remains 50% so upgrading does not make an existing setting more severe.
  public static let maximumAmount = 1.0
  public static let defaultAmount = 0.5

  public static let whiteRampStart = 0.82
  public static let whiteRampEnd = 0.97
  public static let neutralRampStart = 0.03
  public static let neutralRampEnd = 0.10

  public static func clampedAmount(_ amount: Double) -> Double {
    guard amount.isFinite else { return defaultAmount }
    return min(max(amount, 0), maximumAmount)
  }

  public static func whiteLevel(forAmount amount: Double) -> Double {
    1 - clampedAmount(amount)
  }

  /// CPU reference for the compositor LUT. HDR values are normalized by
  /// peak component so colored EDR highlights do not collapse into white.
  public static func selectionMask(
    red: Double,
    green: Double,
    blue: Double
  ) -> Double {
    guard red.isFinite, green.isFinite, blue.isFinite else { return 0 }

    let normalizer = max(max(red, green, blue), 1)
    let red = min(max(red / normalizer, 0), 1)
    let green = min(max(green / normalizer, 0), 1)
    let blue = min(max(blue / normalizer, 0), 1)
    let minimum = min(red, green, blue)
    let maximum = max(red, green, blue)

    let whiteness = smoothstep(
      edge0: whiteRampStart,
      edge1: whiteRampEnd,
      value: minimum
    )
    let neutrality =
      1
      - smoothstep(
        edge0: neutralRampStart,
        edge1: neutralRampEnd,
        value: maximum - minimum
      )
    return min(max(whiteness * neutrality, 0), 1)
  }

  /// Linear-light reference target. The live compositor graph realizes this
  /// target exactly at the fully selected white endpoint.
  public static func gain(
    red: Double,
    green: Double,
    blue: Double,
    amount: Double
  ) -> Double {
    1 - clampedAmount(amount)
      * selectionMask(red: red, green: green, blue: blue)
  }

  private static func smoothstep(
    edge0: Double,
    edge1: Double,
    value: Double
  ) -> Double {
    guard value > edge0 else { return 0 }
    guard value < edge1 else { return 1 }
    let normalized = (value - edge0) / (edge1 - edge0)
    return normalized * normalized * (3 - 2 * normalized)
  }
}

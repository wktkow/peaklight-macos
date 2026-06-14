import AppKit

public struct DisplaySnapshot: Equatable, Identifiable {
    public let id: UInt32
    public let name: String
    public let frame: CGRect
    public let currentEDRHeadroom: Double
    public let potentialEDRHeadroom: Double

    public var isEDRCapable: Bool {
        currentEDRHeadroom > 1.01 || potentialEDRHeadroom > 1.01
    }

    public var usableEDRHeadroom: Double {
        max(1.0, currentEDRHeadroom)
    }

    public init(
        id: UInt32,
        name: String,
        frame: CGRect,
        currentEDRHeadroom: Double,
        potentialEDRHeadroom: Double
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.currentEDRHeadroom = max(1.0, currentEDRHeadroom)
        self.potentialEDRHeadroom = max(1.0, potentialEDRHeadroom)
    }

    public init(screen: NSScreen) {
        self.init(
            id: DisplayModel.screenID(for: screen),
            name: screen.localizedName,
            frame: screen.frame,
            currentEDRHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
            potentialEDRHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        )
    }
}

public final class DisplayModel {
    public init() {}

    public func currentDisplays() -> [DisplaySnapshot] {
        NSScreen.screens.map(DisplaySnapshot.init(screen:))
    }

    public func maximumUsableEDRHeadroom() -> Double {
        let edrDisplays = currentDisplays().filter(\.isEDRCapable)
        return edrDisplays.map(\.usableEDRHeadroom).max() ?? 1.0
    }

    public static func screenID(for screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        if let number {
            return number.uint32Value
        }

        let hash = Int64(screen.frame.debugDescription.hashValue)
        return UInt32(truncatingIfNeeded: UInt64(bitPattern: hash))
    }
}

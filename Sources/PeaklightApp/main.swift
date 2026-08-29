import AppKit
import Darwin
import Foundation
import PeaklightCore

let instanceLock: PeaklightInstanceLock
do {
    instanceLock = try PeaklightInstanceLock.acquire()
} catch PeaklightInstanceLock.AcquisitionError.alreadyRunning {
    Darwin.exit(EXIT_SUCCESS)
} catch {
    let message = "Peaklight could not acquire its process lock: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    Darwin.exit(EXIT_FAILURE)
}

withExtendedLifetime(instanceLock) {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = PeaklightAppDelegate()

        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

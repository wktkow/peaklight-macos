import AppKit
import PeaklightCore

let application = NSApplication.shared
let delegate = PeaklightAppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

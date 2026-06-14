import AppKit
import ApplicationServices

public enum BrightnessKeyDirection: Equatable {
    case up
    case down
}

public enum BrightnessKeyPhase: Equatable {
    case down
    case `repeat`
    case up
}

public final class KeyboardController {
    public typealias Handler = (BrightnessKeyDirection, BrightnessKeyPhase) -> Bool

    public private(set) var isEnabled = false

    private let handler: Handler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start(promptForAccessibility: Bool) -> Bool {
        guard !isEnabled else {
            return true
        }

        guard Self.isAccessibilityTrusted(prompt: promptForAccessibility) else {
            return false
        }

        let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = source
        isEnabled = true
        return true
    }

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isEnabled = false
    }

    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let keyEvent = Self.parseBrightnessKeyEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        let shouldConsume = handler(keyEvent.direction, keyEvent.phase)
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    public static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func parseBrightnessKeyEvent(type: CGEventType, event: CGEvent) -> ParsedBrightnessKeyEvent? {
        guard type == systemDefinedEventType, let nsEvent = NSEvent(cgEvent: event) else {
            return nil
        }

        guard nsEvent.subtype.rawValue == mediaKeySubtype else {
            return nil
        }

        let raw = nsEvent.data1
        let keyCode = (raw & 0xFFFF0000) >> 16
        let keyFlags = raw & 0x0000FFFF
        let keyState = (keyFlags & 0x0000FF00) >> 8
        let isRepeat = (keyFlags & 0x00000001) != 0

        let direction: BrightnessKeyDirection
        switch keyCode {
        case brightnessUpKeyCode:
            direction = .up
        case brightnessDownKeyCode:
            direction = .down
        default:
            return nil
        }

        let phase: BrightnessKeyPhase
        switch keyState {
        case keyDownState:
            phase = isRepeat ? .repeat : .down
        case keyUpState:
            phase = .up
        default:
            return nil
        }

        return ParsedBrightnessKeyEvent(direction: direction, phase: phase)
    }
}

private struct ParsedBrightnessKeyEvent {
    let direction: BrightnessKeyDirection
    let phase: BrightnessKeyPhase
}

private let mediaKeySubtype = 8
private let brightnessUpKeyCode = 2
private let brightnessDownKeyCode = 3
private let keyDownState = 0x0A
private let keyUpState = 0x0B
private let systemDefinedEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue))!

private func keyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<KeyboardController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleTapEvent(type: type, event: event)
}

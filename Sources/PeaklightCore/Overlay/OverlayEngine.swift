import AppKit
import MetalKit
import QuartzCore

public struct OverlayStatus: Equatable {
    public let activeOverlayCount: Int
    public let skippedDisplayNames: [String]
}

public final class OverlayEngine {
    public private(set) var status = OverlayStatus(activeOverlayCount: 0, skippedDisplayNames: [])

    private var overlays: [UInt32: ScreenOverlay] = [:]

    public init() {}

    public func apply(boostFactor: Double, screens: [NSScreen] = NSScreen.screens) {
        guard boostFactor > 1.0001 else {
            disableAll()
            return
        }

        var activeIDs = Set<UInt32>()
        var skippedNames: [String] = []

        for screen in screens {
            let snapshot = DisplaySnapshot(screen: screen)
            guard snapshot.isEDRCapable else {
                skippedNames.append(snapshot.name)
                continue
            }

            let perScreenBoost = min(boostFactor, snapshot.usableEDRHeadroom)
            guard perScreenBoost > 1.0001 else {
                skippedNames.append(snapshot.name)
                continue
            }

            if let overlay = overlays[snapshot.id] {
                overlay.update(screen: screen, boostFactor: perScreenBoost)
                activeIDs.insert(snapshot.id)
            } else if let overlay = ScreenOverlay(screen: screen, boostFactor: perScreenBoost) {
                overlays[snapshot.id] = overlay
                activeIDs.insert(snapshot.id)
            } else {
                skippedNames.append(snapshot.name)
            }
        }

        let staleIDs = overlays.keys.filter { !activeIDs.contains($0) }
        for id in staleIDs {
            overlays[id]?.close()
            overlays[id] = nil
        }

        status = OverlayStatus(activeOverlayCount: overlays.count, skippedDisplayNames: skippedNames)
    }

    public func refresh(screens: [NSScreen] = NSScreen.screens, boostFactor: Double) {
        apply(boostFactor: boostFactor, screens: screens)
    }

    public func disableAll() {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        status = OverlayStatus(activeOverlayCount: 0, skippedDisplayNames: [])
    }
}

private final class ScreenOverlay {
    private let window: NSWindow
    private let view: MTKView
    private let renderer: ConstantColorRenderer

    init?(screen: NSScreen, boostFactor: Double) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }

        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = true
        view.clearColor = Self.clearColor(for: boostFactor)
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.preferredFramesPerSecond = 1
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.wantsLayer = true

        guard let renderer = ConstantColorRenderer(device: device, boostFactor: boostFactor) else {
            return nil
        }
        view.delegate = renderer

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.pixelFormat = .rgba16Float
        }

        view.layer?.compositingFilter = "multiply"

        window.contentView = view
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        self.renderer = renderer

        draw()
    }

    func update(screen: NSScreen, boostFactor: Double) {
        let newFrame = screen.frame
        if window.frame != newFrame {
            window.setFrame(newFrame, display: true)
            view.frame = NSRect(origin: .zero, size: newFrame.size)
        }

        view.clearColor = Self.clearColor(for: boostFactor)
        renderer.update(boostFactor: boostFactor)
        draw()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private func draw() {
        view.needsDisplay = true
        view.draw()
    }

    private static func clearColor(for boostFactor: Double) -> MTLClearColor {
        MTLClearColor(red: boostFactor, green: boostFactor, blue: boostFactor, alpha: 1.0)
    }
}

private final class ConstantColorRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var boostFactor: Double

    init?(device: MTLDevice, boostFactor: Double) {
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        self.boostFactor = boostFactor
    }

    func update(boostFactor: Double) {
        lock.lock()
        self.boostFactor = boostFactor
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        lock.lock()
        let boostFactor = self.boostFactor
        lock.unlock()

        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: boostFactor,
            green: boostFactor,
            blue: boostFactor,
            alpha: 1.0
        )
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        encoder?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

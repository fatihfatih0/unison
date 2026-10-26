import AppKit
import QuartzCore

@MainActor
final class ScreenShade {
    private var windows: [String: NSWindow] = [:]
    private let gamma = DisplayGamma()
    private var brightnesses: [String: Double] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreOverlays() }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOverlays() }
        }
    }

    private func restoreOverlays() {
        for (uuid, brightness) in Array(brightnesses) { set(uuid, brightness: brightness) }
    }

    func set(_ uuid: String, brightness: Double) {
        if brightness >= 0.999 { remove(uuid); return }
        brightnesses[uuid] = brightness
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(id.uint32Value) == 0,
                  let value = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, value) as String).caseInsensitiveCompare(uuid) == .orderedSame
        }) else { removeSurface(uuid); return }
        if let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           screen.maximumExtendedDynamicRangeColorComponentValue <= 1,
           gamma.set(uuid, display: display.uint32Value, brightness: brightness) {
            windows.removeValue(forKey: uuid)?.close()
            return
        }
        gamma.remove(uuid, display: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        let window: NSWindow
        if let existing = windows[uuid] { window = existing }
        else {
            let panel = ShadePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            window = panel
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.alphaValue = 1
            window.colorSpace = .sRGB
            window.hasShadow = false
            window.ignoresMouseEvents = true
            let surface = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            surface.wantsLayer = true
            surface.autoresizingMask = [.width, .height]
            surface.layer?.actions = ["backgroundColor": NSNull(), "opacity": NSNull()]
            window.contentView = surface
            // Keep the dimming surface above fullscreen/Space transition surfaces.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            windows[uuid] = window
        }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true, animate: false) }
        // Window opacity stays at 100%; dimming is encoded in the surface itself.
        // Do not interpolate the shade while AppKit changes fullscreen Spaces.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.backgroundColor = CGColor(gray: 0, alpha: min(0.8, 1 - brightness.clamped))
        CATransaction.commit()
        window.orderFrontRegardless()
    }
    func remove(_ uuid: String) {
        brightnesses.removeValue(forKey: uuid)
        removeSurface(uuid)
    }
    private func removeSurface(_ uuid: String) {
        let display = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  (CFUUIDCreateString(nil, value) as String).caseInsensitiveCompare(uuid) == .orderedSame else { return nil }
            return id
        }.first
        gamma.remove(uuid, display: display)
        windows.removeValue(forKey: uuid)?.close()
    }
    func prune(available: Set<String>) { for uuid in Array(brightnesses.keys) where !available.contains(uuid) { removeSurface(uuid) } }
    func reset() { for uuid in Array(brightnesses.keys) { remove(uuid) } }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

private final class ShadePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

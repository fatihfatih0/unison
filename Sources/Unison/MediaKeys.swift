import AppKit

// Separate decoding from the event tap so both keyboard modes can be verified.
struct VolumeKeyEvent: Equatable {
    let identity: Int
    let action: Int
    let isDown: Bool

    static func media(subtype: Int, data: Int) -> Self? {
        guard subtype == 8 else { return nil }
        let key = (data >> 16) & 0xffff
        let state = (data >> 8) & 0xff
        guard [0, 1, 7].contains(key), [0x0a, 0x0b].contains(state) else { return nil }
        return Self(identity: key, action: key, isDown: state == 0x0a)
    }

    static func function(code: Int, isDown: Bool) -> Self? {
        let action: Int
        switch code {
        case 111: action = 0 // F12
        case 103: action = 1 // F11
        case 109: action = 7 // F10
        default: return nil
        }
        return Self(identity: 1000 + code, action: action, isDown: isDown)
    }
}

struct VolumeKeyConsumption {
    private var pressed: Set<Int> = []

    func owns(_ key: VolumeKeyEvent) -> Bool { pressed.contains(key.identity) }

    mutating func consume(_ key: VolumeKeyEvent, allowed: Bool, handler: (Int) -> Bool) -> Bool {
        if !key.isDown { return pressed.remove(key.identity) != nil }
        if pressed.contains(key.identity) {
            // Volume repeats while held; mute toggles only on the initial press.
            if key.action != 7 { _ = handler(key.action) }
            return true
        }
        guard allowed, handler(key.action) else { return false }
        pressed.insert(key.identity)
        return true
    }
}

// Function-key mode emits ordinary F10/F11/F12 events, which macOS does not
// treat as volume keys. Forward an equivalent media event through the same
// native path, keeping each press/repeat/release together across route changes.
struct NativeFunctionKeyForwarding {
    private var pressed: Set<Int> = []

    mutating func event(for key: VolumeKeyEvent, source: CGEvent, allowed: Bool) -> CGEvent? {
        guard key.identity >= 1000 else { return nil }
        let held = pressed.contains(key.identity)
        guard held || (key.isDown && allowed) else { return nil }
        let state = key.isDown ? 0x0a00 : 0x0b00
        let repeated = key.isDown && held ? 1 : 0
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(source.flags.rawValue)),
                                            timestamp: Double(source.timestamp) / 1_000_000_000,
                                            windowNumber: 0, context: nil, subtype: 8,
                                            data1: (key.action << 16) | state | repeated, data2: -1)?.cgEvent else { return nil }
        if key.isDown { pressed.insert(key.identity) } else { pressed.remove(key.identity) }
        return event
    }
}

@MainActor
final class MediaKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumption = VolumeKeyConsumption()
    private var functionForwarding = NativeFunctionKeyForwarding()
    let handler: (Int) -> Bool
    let nativeVolumeAvailable: () -> Bool
    init(nativeVolumeAvailable: @escaping () -> Bool = { false }, handler: @escaping (Int) -> Bool) {
        self.nativeVolumeAvailable = nativeVolumeAvailable
        self.handler = handler
    }
    func start() -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.consumption = VolumeKeyConsumption()
                    owner.functionForwarding = NativeFunctionKeyForwarding()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let key: VolumeKeyEvent?
                if type == .keyDown || type == .keyUp {
                    key = VolumeKeyEvent.function(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), isDown: type == .keyDown)
                } else if let ns = NSEvent(cgEvent: event), ns.type == .systemDefined {
                    key = VolumeKeyEvent.media(subtype: Int(ns.subtype.rawValue), data: ns.data1)
                } else { key = nil }
                guard let key else { return Unmanaged.passUnretained(event) }
                let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                let unmodified = event.flags.intersection(modifiers).isEmpty
                let nativeVolume = owner.nativeVolumeAvailable()
                if let forwarded = owner.functionForwarding.event(for: key, source: event,
                                                                   allowed: unmodified && nativeVolume && !owner.consumption.owns(key)) {
                    forwarded.tapPostEvent(proxy)
                    return nil
                }
                // Pass real media keys through when our system-volume bridge is
                // ready. macOS changes the volume and presents its own HUD;
                // the property listener forwards that level to every output.
                let delegateToSystem = key.identity < 1000 && nativeVolume
                let allowed = unmodified && !delegateToSystem
                if owner.consumption.consume(key, allowed: allowed, handler: owner.handler) { return nil }
                return Unmanaged.passUnretained(event)
            }
        }
        let mask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    deinit { if let tap { CFMachPortInvalidate(tap) }; if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) } }
}

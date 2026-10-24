import Foundation

struct BluetoothAudioRoute: Codable, Equatable {
    enum Mode: String, Codable { case software, group, device, automatic }
    var bluetoothUID: String
    let outputUIDs: Set<String>
    let mode: Mode
    let volume: Double
    let muted: Bool
    var deviceUID: String? = nil

    static func automatic(bluetoothUID: String, outputs: [Output], volume: Double, muted: Bool) -> BluetoothAudioRoute? {
        guard let speaker = outputs.first(where: { !$0.isAggregate && $0.isBuiltInSpeaker }) else { return nil }
        let targets = outputs.filter { !$0.isAggregate && ($0.uid == speaker.uid || $0.isDisplayAudio) }
        return BluetoothAudioRoute(bluetoothUID: bluetoothUID, outputUIDs: Set(targets.map(\.uid)), mode: .automatic,
                                   volume: volume, muted: muted)
    }
}

// A headset temporarily replaces the configured outputs. If there was no
// managed group, select the built-in speaker and live display audio on return.
struct BluetoothRouteRecovery {
    private(set) var pending: BluetoothAudioRoute?
    private var fallbackUID: String?

    init(pending: BluetoothAudioRoute? = nil) { self.pending = pending }

    mutating func remember(_ route: BluetoothAudioRoute) {
        guard pending == nil, !route.outputUIDs.isEmpty,
              !route.outputUIDs.contains(route.bluetoothUID) else { return }
        pending = route
        fallbackUID = nil
    }

    mutating func cancel() {
        pending = nil; fallbackUID = nil
    }

    mutating func update(current: Output?, outputs: [Output]) -> BluetoothAudioRoute? {
        guard let route = pending else { return nil }
        if let current, current.isBluetooth, outputs.contains(where: { $0.uid == current.uid }) {
            pending?.bluetoothUID = current.uid
            fallbackUID = nil
            return nil
        }

        // AirPods may take well over three seconds to disappear after HAL
        // publishes a fallback. Keep the return armed until actual departure;
        // elapsed time cannot distinguish this from a manual system switch.
        guard !outputs.contains(where: { $0.uid == route.bluetoothUID }) else { return nil }

        // A missing/stale default is itself a disconnect state. Recovery must
        // select a working output instead of waiting for HAL to choose one.
        if let current, outputs.contains(where: { $0.uid == current.uid }) {
            if let fallbackUID, fallbackUID != current.uid { cancel(); return nil }
            fallbackUID = current.uid
        }

        // HDMI can arrive or leave while Bluetooth is in use. Resolve automatic
        // groups from the live audio outputs rather than the entry-time snapshot.
        let automatic = BluetoothAudioRoute.automatic(bluetoothUID: route.bluetoothUID, outputs: outputs,
                                                      volume: route.volume, muted: route.muted)
        if route.mode == .automatic || (route.mode != .device && (automatic?.outputUIDs.count ?? 0) > 1) {
            guard let automatic else { return nil }
            cancel()
            return BluetoothAudioRoute(bluetoothUID: route.bluetoothUID, outputUIDs: automatic.outputUIDs,
                                       mode: route.mode, volume: route.volume, muted: route.muted)
        }

        let available = Set(outputs.filter { !$0.isAggregate }.map(\.uid))
        guard route.outputUIDs.isSubset(of: available) else { return nil }
        if route.mode == .device, !outputs.contains(where: { $0.uid == route.deviceUID }) { return nil }
        cancel()
        return route
    }
}

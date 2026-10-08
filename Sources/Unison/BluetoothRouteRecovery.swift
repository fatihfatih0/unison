import Foundation

struct BluetoothAudioRoute: Codable, Equatable {
    enum Mode: String, Codable { case software, group, device }
    var bluetoothUID: String
    let outputUIDs: Set<String>
    let mode: Mode
    let volume: Double
    let muted: Bool
    var deviceUID: String? = nil
}

// A headset temporarily replaces the configured outputs. Keep their UIDs and
// common level independently of the headset's selection and native volume.
struct BluetoothRouteRecovery {
    private(set) var pending: BluetoothAudioRoute?
    private var fallbackUID: String?
    private var departureDeadline: ContinuousClock.Instant?

    init(pending: BluetoothAudioRoute? = nil) { self.pending = pending }

    mutating func remember(_ route: BluetoothAudioRoute) {
        guard pending == nil, !route.outputUIDs.isEmpty,
              !route.outputUIDs.contains(route.bluetoothUID) else { return }
        pending = route
        fallbackUID = nil; departureDeadline = nil
    }

    mutating func cancel() {
        pending = nil; fallbackUID = nil; departureDeadline = nil
    }

    mutating func update(current: Output?, outputs: [Output], now: ContinuousClock.Instant = .now) -> BluetoothAudioRoute? {
        guard let route = pending, let current else { return nil }
        if current.isBluetooth {
            pending?.bluetoothUID = current.uid
            fallbackUID = nil; departureDeadline = nil
            return nil
        }

        // HAL can publish its built-in fallback before removing the headset.
        // Allow that notification order to settle before treating it as an
        // intentional switch to another connected output.
        if let fallbackUID, fallbackUID != current.uid { cancel(); return nil }
        fallbackUID = current.uid
        if outputs.contains(where: { $0.uid == route.bluetoothUID }) {
            if departureDeadline == nil { departureDeadline = now.advanced(by: .seconds(3)) }
            if let departureDeadline, now >= departureDeadline { cancel() }
            return nil
        }

        let available = Set(outputs.filter { !$0.isAggregate }.map(\.uid))
        guard route.outputUIDs.isSubset(of: available) else { return nil }
        if route.mode == .device, !outputs.contains(where: { $0.uid == route.deviceUID }) { return nil }
        cancel()
        return route
    }
}

import CoreGraphics

/// Dims the display output independently of windows and fullscreen Spaces.
@MainActor
final class DisplayGamma {
    struct Table {
        let red: [Float]
        let green: [Float]
        let blue: [Float]

        static func read(_ display: CGDirectDisplayID) -> Table? {
            let capacity = CGDisplayGammaTableCapacity(display)
            guard capacity >= 2, capacity <= 65536 else { return nil }
            var red = [Float](repeating: 0, count: Int(capacity)), green = red, blue = red
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success,
                  count >= 2, count <= capacity else { return nil }
            let table = Table(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
            guard (table.red + table.green + table.blue).allSatisfy({ $0.isFinite && $0 >= 0 }),
                  max(table.red.max() ?? 0, table.green.max() ?? 0, table.blue.max() ?? 0) > 0.01 else { return nil }
            return table
        }

        func scaled(_ brightness: Double) -> Table {
            let gain = Float(max(0.2, min(1, brightness)))
            return Table(red: red.map { $0 * gain }, green: green.map { $0 * gain }, blue: blue.map { $0 * gain })
        }

        func write(_ display: CGDirectDisplayID) -> Bool {
            CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue) == .success
        }

        func matches(_ other: Table) -> Bool {
            guard red.count == other.red.count, green.count == other.green.count, blue.count == other.blue.count else { return false }
            return Self.channelMatches(red, other.red)
                && Self.channelMatches(green, other.green)
                && Self.channelMatches(blue, other.blue)
        }

        private static func channelMatches(_ values: [Float], _ other: [Float]) -> Bool {
            for index in values.indices {
                let difference: Float = values[index] - other[index]
                guard abs(difference) < 0.002 else { return false }
            }
            return true
        }
    }

    private struct State {
        let display: CGDirectDisplayID
        var original: Table
        var applied: Table
    }
    private var states: [String: State] = [:]

    func set(_ uuid: String, display: CGDirectDisplayID, brightness: Double) -> Bool {
        guard let current = Table.read(display) else { return false }
        var state = states[uuid].flatMap { $0.display == display ? $0 : nil }
            ?? State(display: display, original: current, applied: current)
        // Preserve a new color profile or adjustment made outside Unison.
        if !current.matches(state.applied) && !current.matches(state.original) { state.original = current }
        let target = state.original.scaled(brightness)
        if !current.matches(target) {
            guard target.write(display), let actual = Table.read(display), actual.matches(target) else {
                _ = current.write(display)
                return false
            }
        }
        state.applied = target
        states[uuid] = state
        return true
    }

    func remove(_ uuid: String, display: CGDirectDisplayID?) {
        guard let state = states.removeValue(forKey: uuid), display == state.display,
              let current = Table.read(state.display), current.matches(state.applied) else { return }
        _ = state.original.write(state.display)
    }
}

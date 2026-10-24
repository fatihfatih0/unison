// Saved selections describe the managed group. A separate Bluetooth output
// temporarily owns the native controls while that group is stopped.
enum AudioOutputSelection {
    static func followingSystem(current: Output?, selected: Set<String>, managedRouteActive: Bool) -> Set<String> {
        guard !managedRouteActive, let current, !current.isAggregate else { return selected }
        guard current.isBluetooth || selected.count <= 1 else { return selected }
        return [current.uid]
    }
}

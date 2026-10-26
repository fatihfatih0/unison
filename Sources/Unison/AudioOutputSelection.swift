import CoreAudio

// Saved selections describe the managed group. A separate Bluetooth output
// temporarily owns the native controls while that group is stopped.
enum AudioOutputSelection {
    static func followingSystem(current: Output?, selected: Set<String>, managedRouteActive: Bool) -> Set<String> {
        guard !managedRouteActive, let current, !current.isAggregate else { return selected }
        guard current.isBluetooth || selected.count <= 1 else { return selected }
        return [current.uid]
    }

    static func usesNativeVolumeKeys(currentID: AudioDeviceID, outputs: [Output], processingAudio: Bool, controllerID: AudioDeviceID) -> Bool {
        if processingAudio { return controllerID != 0 && controllerID == currentID }
        // A saved group can remain selected after processing stops. The actual
        // system output still owns native volume and Apple's volume indicator.
        return outputs.contains { $0.id == currentID && $0.volume != nil }
    }
}

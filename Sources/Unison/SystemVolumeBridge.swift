import CoreAudio
import Foundation

@MainActor
final class SystemVolumeBridge {
    private(set) var deviceID: AudioDeviceID = 0
    private(set) var uid = ""
    var amplitude: Double { AudioControl.linearAmplitude(deviceID) ?? lastVolume }
    private var previousID: AudioDeviceID = 0
    private var requestedRoute = false
    private var nativeLevels: [String: Double] = [:]
    private var nativeMutes: [String: Bool] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastVolume = 0.0
    private var lastMuted = false
    private var changed: ((Double, Bool) -> Void)?

    func start(outputs: [Output], value: Double, muted: Bool, preferNamedOutput: Bool = false, renderedUIDs: Set<String> = [], changed: @escaping (Double, Bool) -> Void) throws {
        stop()
        let current = AudioControl.defaultOutput()
        let named = preferNamedOutput ? AudioControl.outputs(includeController: true).first(where: { $0.uid == "org.unison.output" && $0.volume != nil }) : nil
        guard let device = named ?? outputs.first(where: { $0.id == current && !$0.isAggregate && $0.volume != nil })
            ?? outputs.first(where: { !$0.isAggregate && $0.volume != nil && $0.name.localizedCaseInsensitiveContains("MacBook") }) else { return }
        previousID = current; deviceID = device.id; uid = device.uid
        do {
            if uid == "org.unison.output" {
                UserDefaults.standard.set(AudioControl.string(current, kAudioDevicePropertyDeviceUID), forKey: "unisonNamedPreviousOutput")
                // Neutral hardware levels avoid applying the common volume twice.
                for output in outputs where output.volume != nil && renderedUIDs.contains(output.uid) {
                    if let level = AudioControl.volume(output.id) { nativeLevels[output.uid] = level }
                    if let mute = AudioControl.muted(output.id) { nativeMutes[output.uid] = mute }
                }
                // Save recovery information before changing any physical output.
                UserDefaults.standard.set(nativeLevels, forKey: "unisonNormalizedVolumes")
                UserDefaults.standard.set(nativeMutes, forKey: "unisonNormalizedMutes")
                for output in outputs where nativeLevels[output.uid] != nil {
                    try AudioControl.setLevel(output.id, value: 1, muted: false)
                }
            }
            requestedRoute = current != deviceID
            // Reassert the controller after creating the processing aggregate:
            // Bluetooth can complete an older route request during setup.
            try AudioControl.setDefault(deviceID)
            try write(value: value, muted: muted)
            self.changed = changed
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for (target, property) in AudioControl.controlTargets(deviceID, selector) {
                    var address = property
                    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.readChange() }
                    }
                    try AudioControl.check(AudioObjectAddPropertyListenerBlock(target, &address, .main, listener))
                    listeners.append((target, address, listener))
                }
            }
        } catch { stop(); throw error }
    }

    func write(value: Double, muted: Bool) throws {
        guard deviceID != 0 else { return }
        try AudioControl.setLevel(deviceID, value: value, muted: muted)
        lastVolume = AudioControl.volume(deviceID) ?? value
        lastMuted = AudioControl.muted(deviceID) ?? muted
    }

    private func readChange() {
        guard deviceID != 0, let volume = AudioControl.volume(deviceID) else { return }
        let muted = AudioControl.muted(deviceID) ?? false
        guard abs(volume - lastVolume) > 0.001 || muted != lastMuted else { return }
        lastVolume = volume; lastMuted = muted
        changed?(volume, muted)
    }

    func stop() {
        changed = nil
        for (target, property, listener) in listeners {
            var address = property
            _ = AudioObjectRemovePropertyListenerBlock(target, &address, .main, listener)
        }
        listeners.removeAll()
        for (savedUID, level) in nativeLevels {
            if let device = AudioControl.outputs().first(where: { $0.uid == savedUID }), let current = AudioControl.volume(device.id), abs(current - 1) < 0.001 {
                try? AudioControl.setVolume(device.id, value: level)
            }
        }
        for (savedUID, muted) in nativeMutes where muted {
            if let device = AudioControl.outputs().first(where: { $0.uid == savedUID }), AudioControl.muted(device.id) == false {
                try? AudioControl.setMute(device.id, muted: true)
            }
        }
        nativeLevels.removeAll()
        nativeMutes.removeAll()
        if uid == "org.unison.output" {
            UserDefaults.standard.removeObject(forKey: "unisonNormalizedVolumes")
            UserDefaults.standard.removeObject(forKey: "unisonNormalizedMutes")
        }
        let current = AudioControl.defaultOutput()
        // Some routes switch asynchronously. Cancel our pending request even if
        // HAL still reports the previous device when the user stops the engine.
        if requestedRoute, previousID != 0, (current == deviceID || current == previousID),
           AudioControl.outputs().contains(where: { $0.id == previousID }) {
            try? AudioControl.setDefault(previousID)
        }
        if uid == "org.unison.output" { UserDefaults.standard.removeObject(forKey: "unisonNamedPreviousOutput") }
        deviceID = 0; previousID = 0; requestedRoute = false; uid = ""
    }
}

// The system control already attenuates the proxy speaker. Apply the common
// gain in DSP only to other devices, avoiding master × master on that speaker.
enum LinkedVolumeGain {
    static func device(master: Double, relative: Double, calibration: Double, isSystemDevice: Bool, muted: Bool, systemAmplitude: Double? = nil) -> Double {
        guard !muted, master > 0 else { return 0 }
        return ((isSystemDevice ? 1 : systemAmplitude ?? master) * relative * calibration).clamped
    }
}

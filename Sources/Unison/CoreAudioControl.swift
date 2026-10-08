import CoreAudio
import Foundation

struct Output: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let volume: Double?
    let muted: Bool?
    let isAggregate: Bool
    var transportType: UInt32 = 0

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioControl {
    // HAL can otherwise retain a stale default-device value in this process.
    // Keep this subscription for the process lifetime so polling also sees
    // changes requested by other apps and asynchronously completed routes.
    private static let defaultOutputObservation: OSStatus = {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main) { _, _ in
            _ = defaultOutput()
        }
    }()
    private static let deviceListObservation: OSStatus = {
        var property = address(kAudioHardwarePropertyDevices)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main) { _, _ in
            _ = outputs()
        }
    }()
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element) }
    static func check(_ status: OSStatus) throws { guard status == noErr else { throw ControlError.message("Core Audio hatası: \(status)") } }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func defaultOutput() -> AudioDeviceID {
        _ = defaultOutputObservation
        var a = address(kAudioHardwarePropertyDefaultOutputDevice), value: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &value)
        return value
    }
    static func setDefault(_ id: AudioDeviceID) throws {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice), value = id
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value))
    }
    static func elements(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        let candidates: [UInt32] = [0, 1, 2]
        let available = candidates.filter { element in
            var a = address(selector, scope: kAudioObjectPropertyScopeOutput, element: element), settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
        }
        return available.contains(0) ? [0] : available
    }
    static func controlTargets(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [(AudioObjectID, AudioObjectPropertyAddress)] {
        let legacy = elements(id, selector)
        if !legacy.isEmpty { return legacy.map { (id, address(selector, scope: kAudioObjectPropertyScopeOutput, element: $0)) } }
        var listAddress = address(kAudioObjectPropertyControlList), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var controls = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &listAddress, 0, nil, &size, &controls) == noErr else { return [] }
        let wantedClass = selector == kAudioDevicePropertyMute ? kAudioMuteControlClassID : kAudioVolumeControlClassID
        let wantedValue = selector == kAudioDevicePropertyMute ? kAudioBooleanControlPropertyValue : kAudioLevelControlPropertyScalarValue
        return controls.compactMap { control in
            func integer(_ selector: AudioObjectPropertySelector) -> UInt32? {
                var a = address(selector), v: UInt32 = 0, bytes: UInt32 = 4
                return AudioObjectGetPropertyData(control, &a, 0, nil, &bytes, &v) == noErr ? v : nil
            }
            guard integer(kAudioObjectPropertyClass) == wantedClass,
                  integer(kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput else { return nil }
            var a = address(wantedValue), settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(control, &a, &settable) == noErr, settable.boolValue else { return nil }
            return (control, a)
        }
    }
    static func volume(_ id: AudioDeviceID) -> Double? {
        let values: [Double] = controlTargets(id, kAudioDevicePropertyVolumeScalar).compactMap { target, property in
            var a = property, value: Float32 = 0, size: UInt32 = 4
            return AudioObjectGetPropertyData(target, &a, 0, nil, &size, &value) == noErr ? Double(value) : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    static func linearAmplitude(_ id: AudioDeviceID) -> Double? {
        let values: [Double] = controlTargets(id, kAudioDevicePropertyVolumeScalar).compactMap { target, property in
            var a = property
            a.mSelector = target == id ? kAudioDevicePropertyVolumeDecibels : kAudioLevelControlPropertyDecibelValue
            var decibels: Float32 = 0, size: UInt32 = 4
            guard AudioObjectHasProperty(target, &a), AudioObjectGetPropertyData(target, &a, 0, nil, &size, &decibels) == noErr else { return nil }
            return pow(10, Double(decibels) / 20).clamped
        }
        return values.isEmpty ? volume(id) : values.reduce(0, +) / Double(values.count)
    }
    static func muted(_ id: AudioDeviceID) -> Bool? {
        guard let (target, property) = controlTargets(id, kAudioDevicePropertyMute).first else { return nil }
        var a = property, value: UInt32 = 0, size: UInt32 = 4
        return AudioObjectGetPropertyData(target, &a, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }
    static func setVolume(_ id: AudioDeviceID, value: Double) throws {
        let targets = controlTargets(id, kAudioDevicePropertyVolumeScalar)
        guard !targets.isEmpty else { throw ControlError.message("Bu çıkış Core Audio ses ayarını desteklemiyor.") }
        for (target, property) in targets {
            var a = property, v = Float32(value.clamped)
            try check(AudioObjectSetPropertyData(target, &a, 0, nil, 4, &v))
        }
    }
    static func setMute(_ id: AudioDeviceID, muted: Bool) throws {
        let targets = controlTargets(id, kAudioDevicePropertyMute)
        guard !targets.isEmpty else { throw ControlError.message("Çıkış donanım sessize almayı desteklemiyor.") }
        for (target, property) in targets {
            var a = property, v: UInt32 = muted ? 1 : 0
            try check(AudioObjectSetPropertyData(target, &a, 0, nil, 4, &v))
        }
    }
    static func setLevel(_ id: AudioDeviceID, value: Double, muted: Bool) throws {
        let supportsMute = self.muted(id) != nil
        try setVolume(id, value: muted && !supportsMute ? 0 : value)
        if supportsMute { try setMute(id, muted: muted) }
    }
    static func outputs(includeController: Bool = false) -> [Output] {
        _ = deviceListObservation
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive), alive: UInt32 = 1, aliveSize: UInt32 = 4
            if AudioObjectGetPropertyData(id, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr, alive == 0 { return nil }
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var transport = address(kAudioDevicePropertyTransportType), kind: UInt32 = 0, kindSize: UInt32 = 4
            _ = AudioObjectGetPropertyData(id, &transport, 0, nil, &kindSize, &kind)
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            guard includeController || uid != "org.unison.output" else { return nil }
            return Output(id: id, uid: uid, name: string(id, kAudioObjectPropertyName), volume: volume(id), muted: muted(id), isAggregate: kind == kAudioDeviceTransportTypeAggregate, transportType: kind)
        }
    }
    static func aggregate(_ outputs: [Output]) throws -> AudioDeviceID {
        guard outputs.count >= 2 else { throw ControlError.message("En az iki çıkış seçin.") }
        let uid = "org.unison.group.\(UUID().uuidString)"
        let subdevices = outputs.enumerated().map { index, device in [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1] as [String: Any] }
        // The native group exposes one shared stereo stream to ordinary apps.
        // SoftwareAudio uses the opposite mode to write every output separately.
        let description: [String: Any] = [kAudioAggregateDeviceNameKey: "Unison Çoklu Çıkış", kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceSubDeviceListKey: subdevices, kAudioAggregateDeviceMainSubDeviceKey: outputs[0].uid, kAudioAggregateDeviceIsStackedKey: 1, kAudioAggregateDeviceIsPrivateKey: 0]
        var id: AudioDeviceID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id))
        return id
    }
    static func subdeviceUIDs(_ id: AudioDeviceID) -> Set<String> {
        var a = address(kAudioAggregateDevicePropertyFullSubDeviceList), size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), array: Unmanaged<CFArray>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &array) == noErr, let array else { return [] }
        return Set(array.takeRetainedValue() as? [String] ?? [])
    }
}

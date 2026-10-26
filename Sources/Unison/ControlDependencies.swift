import CoreAudio
import Foundation

// Hardware boundaries let routing and lifecycle tests run without changing
// the user's sound output, capture permissions, displays or preferences.
@MainActor
protocol AudioHardware {
    func outputs(includeController: Bool) -> [Output]
    func defaultOutput() -> AudioDeviceID
    func setDefault(_ id: AudioDeviceID) throws
    func volume(_ id: AudioDeviceID) -> Double?
    func muted(_ id: AudioDeviceID) -> Bool?
    func linearAmplitude(_ id: AudioDeviceID) -> Double?
    func setVolume(_ id: AudioDeviceID, value: Double) throws
    func setMute(_ id: AudioDeviceID, muted: Bool) throws
    func setLevel(_ id: AudioDeviceID, value: Double, muted: Bool) throws
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String
    func aggregate(_ outputs: [Output]) throws -> AudioDeviceID
    func destroyAggregate(_ id: AudioDeviceID) -> OSStatus
    func subdeviceUIDs(_ id: AudioDeviceID) -> Set<String>
}

extension AudioHardware {
    func outputs() -> [Output] { outputs(includeController: false) }
}

struct CoreAudioHardware: AudioHardware {
    nonisolated init() {}
    func outputs(includeController: Bool) -> [Output] { AudioControl.outputs(includeController: includeController) }
    func defaultOutput() -> AudioDeviceID { AudioControl.defaultOutput() }
    func setDefault(_ id: AudioDeviceID) throws { try AudioControl.setDefault(id) }
    func volume(_ id: AudioDeviceID) -> Double? { AudioControl.volume(id) }
    func muted(_ id: AudioDeviceID) -> Bool? { AudioControl.muted(id) }
    func linearAmplitude(_ id: AudioDeviceID) -> Double? { AudioControl.linearAmplitude(id) }
    func setVolume(_ id: AudioDeviceID, value: Double) throws { try AudioControl.setVolume(id, value: value) }
    func setMute(_ id: AudioDeviceID, muted: Bool) throws { try AudioControl.setMute(id, muted: muted) }
    func setLevel(_ id: AudioDeviceID, value: Double, muted: Bool) throws { try AudioControl.setLevel(id, value: value, muted: muted) }
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String { AudioControl.string(id, selector) }
    func aggregate(_ outputs: [Output]) throws -> AudioDeviceID { try AudioControl.aggregate(outputs) }
    func destroyAggregate(_ id: AudioDeviceID) -> OSStatus { AudioHardwareDestroyAggregateDevice(id) }
    func subdeviceUIDs(_ id: AudioDeviceID) -> Set<String> { AudioControl.subdeviceUIDs(id) }
}

@MainActor
protocol SoftwareAudioEngine: AnyObject {
    var outputUIDs: [String] { get }
    var isRunning: Bool { get }
    var callbacks: UInt32 { get }
    var signalBlocks: UInt32 { get }
    var inputLayout: UInt32 { get }
    var outputLayout: UInt32 { get }
    var deliveredBlocks: [UInt32] { get }
    var inputPeak: Double { get }
    var outputPeaks: [Double] { get }
    func start(outputs: [Output], calibration: [String: Double]) async throws
    func gain(_ value: Double)
    func deviceGain(_ uid: String, value: Double)
    func isolateCapture(processID: AudioObjectID) throws
    func activate(master: Double) throws
    func stop()
}

extension SoftwareAudio: SoftwareAudioEngine {}

protocol DisplayDDC: Actor {
    func discover(builtInIDs: Set<String>) throws -> [Monitor]
    func send(_ id: String, feature: String, value: Double, max: Int) throws
    func read(_ id: String, feature: String) throws -> (value: Double, max: Int)
}

extension DDC: DisplayDDC {}

@MainActor
protocol DisplayShading: AnyObject {
    func set(_ uuid: String, brightness: Double)
    func remove(_ uuid: String)
    func prune(available: Set<String>)
    func reset()
}

extension ScreenShade: DisplayShading {}

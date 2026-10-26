import CoreAudio
import XCTest
@testable import Unison

@MainActor
private final class FakeAudioHardware: AudioHardware {
    var devices: [Output]
    var current: AudioDeviceID
    var levels: [AudioDeviceID: Double] = [:]
    var mutes: [AudioDeviceID: Bool] = [:]
    var routeRequests: [AudioDeviceID] = []
    var deferredDevice: AudioDeviceID?
    init(_ devices: [Output], current: AudioDeviceID) { self.devices = devices; self.current = current }
    func outputs(includeController: Bool) -> [Output] {
        devices.filter { includeController || $0.uid != "org.unison.output" }.map { device in
            Output(id: device.id, uid: device.uid, name: device.name, volume: volume(device.id), muted: muted(device.id),
                   isAggregate: device.isAggregate, transportType: device.transportType)
        }
    }
    func defaultOutput() -> AudioDeviceID { current }
    func setDefault(_ id: AudioDeviceID) throws {
        guard devices.contains(where: { $0.id == id }) else { throw ControlError.message("Missing output") }
        routeRequests.append(id)
        if deferredDevice != id { current = id }
    }
    func volume(_ id: AudioDeviceID) -> Double? { levels[id] ?? devices.first(where: { $0.id == id })?.volume }
    func muted(_ id: AudioDeviceID) -> Bool? { mutes[id] ?? devices.first(where: { $0.id == id })?.muted }
    func linearAmplitude(_ id: AudioDeviceID) -> Double? { volume(id) }
    func setVolume(_ id: AudioDeviceID, value: Double) throws { levels[id] = value }
    func setMute(_ id: AudioDeviceID, muted: Bool) throws { mutes[id] = muted }
    func setLevel(_ id: AudioDeviceID, value: Double, muted: Bool) throws {
        if self.muted(id) == nil { levels[id] = muted ? 0 : value }
        else { levels[id] = value; mutes[id] = muted }
    }
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        devices.first(where: { $0.id == id })?.uid ?? ""
    }
    func aggregate(_ outputs: [Output]) throws -> AudioDeviceID {
        let group = Output(id: 70, uid: "org.unison.group.test", name: "Test group", volume: nil, muted: nil, isAggregate: true)
        devices.append(group)
        return group.id
    }
    func destroyAggregate(_ id: AudioDeviceID) -> OSStatus { devices.removeAll { $0.id == id }; return noErr }
    func subdeviceUIDs(_ id: AudioDeviceID) -> Set<String> { [] }
}

@MainActor
private final class FakeSoftwareAudio: SoftwareAudioEngine {
    var outputUIDs: [String] = []
    var isRunning = false
    var callbacks: UInt32 = 1
    var signalBlocks: UInt32 = 0
    var inputLayout: UInt32 = 0
    var outputLayout: UInt32 = 0
    var deliveredBlocks: [UInt32] { outputUIDs.map { _ in isRunning ? 1 : 0 } }
    var inputPeak = 0.0
    var outputPeaks: [Double] = []
    var failuresRemaining = 0
    var startAttempts = 0
    func start(outputs: [Output], calibration: [String: Double]) async throws {
        startAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ControlError.message("Aggregate streams not ready")
        }
        outputUIDs = outputs.map(\.uid); isRunning = true
    }
    func gain(_ value: Double) {}
    func deviceGain(_ uid: String, value: Double) {}
    func isolateCapture(processID: AudioObjectID) throws {}
    func activate(master: Double) throws {}
    func stop() { outputUIDs = []; isRunning = false }
}

private actor FakeDDC: DisplayDDC {
    struct Write: Equatable { let id: String; let feature: String; let value: Double }
    var displays: [Monitor] = []
    var writes: [Write] = []
    func setDisplays(_ displays: [Monitor]) { self.displays = displays }
    func recordedWrites() -> [Write] { writes }
    func discover(builtInIDs: Set<String>) throws -> [Monitor] { displays }
    func send(_ id: String, feature: String, value: Double, max: Int) throws {
        writes.append(Write(id: id, feature: feature, value: value))
    }
    func read(_ id: String, feature: String) throws -> (value: Double, max: Int) {
        (writes.last(where: { $0.id == id && $0.feature == feature })?.value ?? 0.5, 100)
    }
}

@MainActor
private final class FakeShade: DisplayShading {
    var applied: [String: Double] = [:]
    func set(_ uuid: String, brightness: Double) { applied[uuid] = brightness }
    func remove(_ uuid: String) { applied.removeValue(forKey: uuid) }
    func prune(available: Set<String>) { applied = applied.filter { available.contains($0.key) } }
    func reset() { applied.removeAll() }
}

final class ControlModelRegressionTests: XCTestCase {
    private let speaker = Output(id: 10, uid: "speaker", name: "MacBook", volume: 0.4, muted: false,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeBuiltIn)
    private let hdmi = Output(id: 20, uid: "hdmi", name: "Display", volume: nil, muted: nil,
                              isAggregate: false, transportType: kAudioDeviceTransportTypeHDMI)
    private let headset = Output(id: 30, uid: "headset", name: "Headset", volume: 0.8, muted: false,
                                 isAggregate: false, transportType: kAudioDeviceTransportTypeBluetooth)
    private let controller = Output(id: 40, uid: "org.unison.output", name: "Unison", volume: 0.5, muted: false, isAggregate: false)

    private func preferences() -> UserDefaults {
        let name = "org.unison.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor private func model(audio: FakeAudioHardware, defaults: UserDefaults? = nil,
                                  engine: FakeSoftwareAudio? = nil, ddc: FakeDDC = FakeDDC(), shade: FakeShade? = nil) -> ControlModel {
        ControlModel(defaults: defaults ?? preferences(), audio: audio, softwareAudio: engine ?? FakeSoftwareAudio(),
                     ddc: ddc, shade: shade ?? FakeShade(), startServices: false)
    }

    @MainActor private func wait(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let ready = try await AudioReadiness.wait(timeout: timeout, isReady: condition)
        XCTAssertTrue(ready, "Timed out waiting for model transition")
    }

    @MainActor func testBluetoothReturnRetriesTransientFailureThenStartsBothOutputs() async throws {
        let defaults = preferences()
        let audio = FakeAudioHardware([speaker, hdmi, headset, controller], current: speaker.id)
        let engine = FakeSoftwareAudio(); engine.failuresRemaining = 1
        let model = model(audio: audio, defaults: defaults, engine: engine)
        defer { model.stopSoftwareAudio() }
        // Exercise actual entry and departure notifications through the model.
        audio.current = headset.id; model.pollAudio()
        XCTAssertNotNil(defaults.data(forKey: "bluetoothAudioRoute"))
        audio.devices.removeAll { $0.id == headset.id }; audio.current = speaker.id
        model.pollAudio()
        try await wait { engine.startAttempts == 1 && !model.audioStarting }
        XCTAssertNotNil(defaults.data(forKey: "bluetoothAudioRoute"))
        XCTAssertEqual(audio.current, speaker.id)
        try await wait { model.pollAudio(); return engine.startAttempts == 2 && engine.isRunning }
        XCTAssertEqual(Set(engine.outputUIDs), [speaker.uid, hdmi.uid])
        XCTAssertNotNil(defaults.data(forKey: "bluetoothAudioRoute"), "Keep return while awaiting the first signal")
        engine.signalBlocks = 1
        try await wait { model.softwareAudioRunning }
        XCTAssertEqual(model.selected, [speaker.uid, hdmi.uid])
        XCTAssertEqual(audio.current, controller.id)
        XCTAssertNil(defaults.data(forKey: "bluetoothAudioRoute"))
        XCTAssertEqual(engine.startAttempts, 2)
    }

    @MainActor func testReturnIsCommittedOnlyAfterHALCompletesNamedRoute() async throws {
        let defaults = preferences()
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .software, volume: 0.35, muted: false)
        defaults.set(try JSONEncoder().encode(saved), forKey: "bluetoothAudioRoute")
        let audio = FakeAudioHardware([speaker, hdmi, controller], current: speaker.id)
        audio.deferredDevice = controller.id
        let engine = FakeSoftwareAudio(); engine.signalBlocks = 1
        let model = model(audio: audio, defaults: defaults, engine: engine)
        defer { model.stopSoftwareAudio() }
        model.pollAudio()
        try await wait { model.softwareAudioRunning }
        model.pollAudio()
        XCTAssertEqual(audio.current, speaker.id)
        XCTAssertNotNil(defaults.data(forKey: "bluetoothAudioRoute"))
        audio.current = controller.id
        model.pollAudio()
        XCTAssertNil(defaults.data(forKey: "bluetoothAudioRoute"))
        XCTAssertTrue(model.softwareAudioRunning)
    }

    @MainActor func testDeferredNativeGroupReturnWaitsForHALAndHonorsSubsequentRouteChange() async throws {
        let defaults = preferences()
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .group, volume: 0.35, muted: false)
        defaults.set(try JSONEncoder().encode(saved), forKey: "bluetoothAudioRoute")
        let audio = FakeAudioHardware([speaker, hdmi], current: speaker.id)
        audio.deferredDevice = 70
        let model = model(audio: audio, defaults: defaults)
        model.pollAudio(); model.pollAudio()
        XCTAssertTrue(model.groupRunning)
        XCTAssertNotNil(defaults.data(forKey: "bluetoothAudioRoute"))
        audio.current = 70; model.pollAudio()
        XCTAssertNil(defaults.data(forKey: "bluetoothAudioRoute"))
        audio.current = speaker.id; model.pollAudio()
        XCTAssertFalse(model.groupRunning, "Completed transitions must not mask a subsequent user switch")
        XCTAssertFalse(audio.devices.contains(where: { $0.id == 70 }))
    }

    @MainActor func testManualRouteSelectionDuringRetryDoesNotResumeOldGroup() async throws {
        let defaults = preferences()
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .automatic, volume: 0.35, muted: false)
        defaults.set(try JSONEncoder().encode(saved), forKey: "bluetoothAudioRoute")
        let audio = FakeAudioHardware([speaker, hdmi, controller], current: speaker.id)
        let engine = FakeSoftwareAudio(); engine.failuresRemaining = 1
        let model = model(audio: audio, defaults: defaults, engine: engine)
        model.pollAudio()
        try await wait { engine.startAttempts == 1 && !model.audioStarting }
        model.routeTo(speaker)
        XCTAssertNil(defaults.data(forKey: "bluetoothAudioRoute"))
        try await Task.sleep(for: .milliseconds(1100))
        model.pollAudio()
        XCTAssertEqual(engine.startAttempts, 1)
        XCTAssertEqual(model.selected, [speaker.uid])
    }

    @MainActor func testExplicitStopCancelsFailedBluetoothReturn() async throws {
        let defaults = preferences()
        let route = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .automatic, volume: 0.3, muted: false)
        defaults.set(try JSONEncoder().encode(route), forKey: "bluetoothAudioRoute")
        let audio = FakeAudioHardware([speaker, hdmi, controller], current: speaker.id)
        let engine = FakeSoftwareAudio(); engine.failuresRemaining = 1
        let model = model(audio: audio, defaults: defaults, engine: engine)
        model.pollAudio()
        try await wait { engine.startAttempts == 1 && !model.audioStarting }
        model.stopSoftwareAudio()
        XCTAssertNil(defaults.data(forKey: "bluetoothAudioRoute"))
        try await Task.sleep(for: .milliseconds(1100))
        model.pollAudio()
        XCTAssertEqual(engine.startAttempts, 1)
    }

    @MainActor func testMenuQuitPreservesReturnAcrossRestartAndCannotRestartDuringShutdown() async throws {
        let defaults = preferences()
        let saved = BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: [speaker.uid, hdmi.uid],
                                        mode: .software, volume: 0.35, muted: true)
        defaults.set(try JSONEncoder().encode(saved), forKey: "bluetoothAudioRoute")
        let audio = FakeAudioHardware([speaker, hdmi, controller], current: speaker.id)
        let engine = FakeSoftwareAudio()
        let model = model(audio: audio, defaults: defaults, engine: engine)
        XCTAssertTrue(model.prepareForTermination())
        model.pollAudio(); model.startSoftwareAudio()
        await Task.yield()
        XCTAssertEqual(engine.startAttempts, 0)
        let stored = try XCTUnwrap(defaults.data(forKey: "bluetoothAudioRoute"))
        XCTAssertEqual(try JSONDecoder().decode(BluetoothAudioRoute.self, from: stored), saved)
        let reopened = self.model(audio: audio, defaults: defaults, engine: engine)
        defer { reopened.stopSoftwareAudio() }
        reopened.pollAudio()
        try await wait { engine.isRunning }
        XCTAssertEqual(reopened.master, 0.35)
        XCTAssertTrue(reopened.masterMuted)
        XCTAssertEqual(Set(engine.outputUIDs), [speaker.uid, hdmi.uid])
    }

    @MainActor func testNativeCalibrationSurvivesPollingMuteAndUnmute() async throws {
        let audio = FakeAudioHardware([speaker], current: speaker.id)
        let model = model(audio: audio)
        model.selected = [speaker.uid]; model.calibrations[speaker.uid] = 0.5
        model.master = 0.8; model.applyMaster()
        for _ in 0..<4 {
            model.pollAudio()
            XCTAssertEqual(model.master, 0.8, accuracy: 0.001)
            model.masterMuted = true; model.applyMaster(); model.pollAudio()
            model.masterMuted = false; model.applyMaster(); model.pollAudio()
            XCTAssertEqual(try XCTUnwrap(audio.volume(speaker.id)), 0.4, accuracy: 0.001)
        }
        // A real system-volume change is interpreted in the same scale.
        try audio.setVolume(speaker.id, value: 0.3); model.pollAudio()
        XCTAssertEqual(model.master, 0.6, accuracy: 0.001)
        model.masterMuted = true; model.applyMaster(); model.pollAudio()
        model.masterMuted = false; model.applyMaster()
        XCTAssertEqual(try XCTUnwrap(audio.volume(speaker.id)), 0.3, accuracy: 0.001)
    }

    @MainActor func testZeroCalibrationAndDeviceWithoutMutePreserveStoredMaster() async throws {
        let device = Output(id: 60, uid: "usb", name: "USB", volume: 0.4, muted: nil, isAggregate: false)
        let audio = FakeAudioHardware([device], current: device.id)
        let model = model(audio: audio)
        model.selected = [device.uid]; model.calibrations[device.uid] = 0.5; model.master = 0.8
        model.applyMaster(); model.masterMuted = true; model.applyMaster(); model.pollAudio()
        XCTAssertEqual(model.master, 0.8)
        XCTAssertEqual(audio.volume(device.id), 0)
        model.masterMuted = false; model.applyMaster(); model.pollAudio()
        XCTAssertEqual(audio.volume(device.id), 0.4)
        model.calibrations[device.uid] = 0; model.applyMaster(); model.pollAudio()
        XCTAssertEqual(model.master, 0.8)
        XCTAssertEqual(audio.volume(device.id), 0)
    }

    @MainActor func testLinkedMonitorReceivesMasterWhileSoftwareAudioIsStartingAndRunning() async throws {
        for running in [false, true] {
            let audio = FakeAudioHardware([speaker, hdmi], current: speaker.id)
            let ddc = FakeDDC()
            let model = model(audio: audio, ddc: ddc)
            model.monitors = [Monitor(id: "display", name: "Display", volume: 0.7)]
            model.linkedMonitors = ["display"]
            model.audioStarting = !running; model.softwareAudioRunning = running
            model.master = 0.6; model.calibrations["display.display"] = 0.5
            model.applyMaster()
            XCTAssertEqual(model.monitors[0].volume, 0.3)
            // Let the queued hardware write run before submitting mute.
            for _ in 0..<20 { if !(await ddc.recordedWrites()).isEmpty { break }; await Task.yield() }
            let first = await ddc.recordedWrites()
            XCTAssertEqual(first.last?.value, 0.3)
            model.masterMuted = true; model.applyMaster()
            for _ in 0..<20 { if (await ddc.recordedWrites()).last?.value == 0 { break }; await Task.yield() }
            let muted = await ddc.recordedWrites()
            XCTAssertEqual(muted.last?.value, 0)
            model.stopSoftwareAudio()
        }
    }

    @MainActor func testNativeVolumeAndMuteChangesPropagateToLinkedMonitorWithoutFeedbackWrites() async throws {
        let audio = FakeAudioHardware([speaker], current: speaker.id)
        let ddc = FakeDDC()
        let model = model(audio: audio, ddc: ddc)
        model.selected = [speaker.uid]
        model.monitors = [Monitor(id: "display", name: "Display", volume: 0.7)]
        model.linkedMonitors = ["display"]
        try audio.setLevel(speaker.id, value: 0.2, muted: false)
        model.pollAudio()
        XCTAssertEqual(model.monitors[0].volume, 0.2)
        for _ in 0..<20 { if !(await ddc.recordedWrites()).isEmpty { break }; await Task.yield() }
        let count = await ddc.recordedWrites().count
        for _ in 0..<10 { model.pollAudio(); await Task.yield() }
        let unchangedCount = await ddc.recordedWrites().count
        XCTAssertEqual(unchangedCount, count)
        try audio.setMute(speaker.id, muted: true); model.pollAudio()
        XCTAssertEqual(model.monitors[0].volume, 0)
        XCTAssertEqual(audio.volume(speaker.id), 0.2, "Native callback must not write a second hardware gain")
    }

    @MainActor func testDisconnectedPreviousOutputFallsBackToBuiltInSpeaker() async throws {
        let audio = FakeAudioHardware([hdmi, speaker, controller], current: hdmi.id)
        let bridge = SystemVolumeBridge(audio: audio, defaults: preferences(), observeChanges: false)
        try bridge.start(outputs: audio.outputs(), value: 0.5, muted: false, preferNamedOutput: true) { _, _ in }
        XCTAssertEqual(audio.current, controller.id)
        audio.devices.removeAll { $0.id == hdmi.id }
        bridge.stop()
        XCTAssertEqual(audio.current, speaker.id)
    }

    @MainActor func testBridgeStopPreservesUserRouteAndRestoresAvailablePreviousRoute() async throws {
        for changedByUser in [false, true] {
            let audio = FakeAudioHardware([speaker, hdmi, headset, controller], current: hdmi.id)
            let bridge = SystemVolumeBridge(audio: audio, defaults: preferences(), observeChanges: false)
            try bridge.start(outputs: audio.outputs(), value: 0.5, muted: false, preferNamedOutput: true) { _, _ in }
            if changedByUser { audio.current = headset.id }
            bridge.stop()
            XCTAssertEqual(audio.current, changedByUser ? headset.id : hdmi.id)
        }
    }

    @MainActor func testDisplayReconnectReappliesDimmingAndHardwareTakeoverClearsIt() async throws {
        let audio = FakeAudioHardware([speaker], current: speaker.id)
        let ddc = FakeDDC(), shade = FakeShade()
        let model = model(audio: audio, ddc: ddc, shade: shade)
        let display = Monitor(id: "external", name: "Display")
        await ddc.setDisplays([display]); await model.refreshDisplays()
        model.setBrightness(display, value: 0.3)
        XCTAssertEqual(shade.applied[display.id], 0.3)
        await ddc.setDisplays([]); await model.refreshDisplays()
        XCTAssertNil(shade.applied[display.id])
        await ddc.setDisplays([display]); await model.refreshDisplays()
        XCTAssertEqual(model.brightnessValue(display), 0.3)
        XCTAssertEqual(shade.applied[display.id], 0.3)
        var hardwareDisplay = display; hardwareDisplay.brightness = 0.6
        await ddc.setDisplays([hardwareDisplay]); await model.refreshDisplays()
        XCTAssertNil(shade.applied[display.id])
        XCTAssertNil(model.softwareBrightness[display.id])
    }
}

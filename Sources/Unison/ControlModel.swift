import SwiftUI
import CoreAudio
import AppKit
import ServiceManagement

@MainActor
final class ControlModel: ObservableObject {
    @Published var outputs: [Output] = []
    @Published var monitors: [Monitor] = []
    @Published var selected: Set<String> = []
    @Published var linkedMonitors: Set<String> = []
    @Published var calibrations: [String: Double] = [:]
    @Published var master = 0.5
    @Published var masterMuted = false
    @Published var defaultID: AudioDeviceID = 0
    @Published var message = ""
    @Published var busy = false
    @Published var groupRunning = false
    @Published var keysEnabled = false
    @Published var softwareBrightness: [String: Double] = [:]
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var softwareAudioRunning = false
    @Published var audioStarting = false
    @Published var selectedDisplays: Set<String> = []
    @Published var masterBrightness = 1.0
    @Published var deviceGains: [String: Double] = [:]
    @Published var deviceMuted: Set<String> = []
    private let softwareAudio: any SoftwareAudioEngine
    private let systemVolume: SystemVolumeBridge
    private let audio: any AudioHardware
    private let systemIntegrationEnabled: Bool
    private var shuttingDown = false
    private var bluetoothNativeTransition: AudioRouteTransition?
    private let ddc: any DisplayDDC
    private let shade: any DisplayShading
    private var timer: Timer?
    private var brightnessTimer: Timer?
    private var ticks = 0
    private var displaySelectionInitialized = false
    private var groupTransition: AudioRouteTransition?
    private var aggregateID: AudioDeviceID?
    private var originalUID: String?
    private var bluetoothRecovery = BluetoothRouteRecovery()
    private let defaults: UserDefaults
    private var mediaKeys: MediaKeys?
    private var termination: NSObjectProtocol?
    private var terminationSignal: DispatchSourceSignal?
    private var audioGeneration = 0
    private var audioTask: Task<Void, Never>?
    private var nativeVolumeDevice: AudioDeviceID = 0
    private var nativeVolumeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var audioRouteListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var audioAvailabilityListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var refreshingAudioRoute = false
    private struct DisplayControl: Hashable { let id: String; let feature: String }
    private var displayReadback: [String: Task<Void, Never>] = [:]
    private lazy var displayWrites = LatestValueQueue<DisplayControl> { [weak self] target, value in
        guard let self, let monitor = monitors.first(where: { $0.id == target.id }) else { return }
        do {
            try await ddc.send(target.id, feature: target.feature, value: value, max: target.feature == "luminance" ? monitor.brightnessMax : monitor.volumeMax)
        } catch { message = error.localizedDescription }
    }

    init(defaults: UserDefaults = .standard, audio: any AudioHardware = CoreAudioHardware(),
         softwareAudio: (any SoftwareAudioEngine)? = nil, ddc: any DisplayDDC = DDC(),
         shade: (any DisplayShading)? = nil, startServices: Bool = true) {
        self.defaults = defaults
        self.audio = audio
        self.softwareAudio = softwareAudio ?? SoftwareAudio()
        self.systemVolume = SystemVolumeBridge(audio: audio, defaults: defaults, observeChanges: startServices)
        self.ddc = ddc
        self.shade = shade ?? ScreenShade()
        systemIntegrationEnabled = startServices
        selected = Set(defaults.stringArray(forKey: "selectedOutputs") ?? [])
        if let data = defaults.data(forKey: "bluetoothAudioRoute"),
           let route = try? JSONDecoder().decode(BluetoothAudioRoute.self, from: data) {
            bluetoothRecovery = BluetoothRouteRecovery(pending: route)
        }
        if let saved = defaults.stringArray(forKey: "selectedDisplays") { selectedDisplays = Set(saved); displaySelectionInitialized = true }
        linkedMonitors = Set(defaults.stringArray(forKey: "linkedMonitors") ?? [])
        calibrations = defaults.dictionary(forKey: "calibrations") as? [String: Double] ?? [:]
        if defaults.object(forKey: "master") != nil { master = defaults.double(forKey: "master").clamped }
        outputs = audio.outputs(); defaultID = audio.defaultOutput()
        guard startServices else { return }
        if selected.isEmpty, let current = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) { selected.insert(current.uid) }
        recoverRouting()
        observeNativeVolume()
        let savedTargets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if let current = outputs.first(where: { $0.id == defaultID && $0.isBluetooth }),
           selected.count > 1 || (savedTargets.count == 1 && savedTargets[0].volume == nil) {
            bluetoothRecovery.remember(BluetoothAudioRoute(bluetoothUID: current.uid, outputUIDs: selected,
                                                         mode: .software, volume: master, muted: masterMuted))
            persistBluetoothRecovery()
        }
        if let headset = outputs.first(where: { $0.id == defaultID && $0.isBluetooth }) {
            rememberBluetoothRoute(headset)
        }
        if selected.count <= 1, savedTargets.allSatisfy({ $0.volume != nil }),
           let current = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) {
            selected = [current.uid]
            defaults.set(Array(selected), forKey: "selectedOutputs")
            if let value = audio.volume(current.id) { syncNativeVolume(value: value, muted: audio.muted(current.id)) }
        }
        observeAudioRouting()
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.prepareForTermination() }
        }
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { NSApp.terminate(nil) }
        signalSource.resume(); terminationSignal = signalSource
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        let brightnessTimer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNativeBrightness() }
        }
        RunLoop.main.add(brightnessTimer, forMode: .common)
        self.brightnessTimer = brightnessTimer
        Task {
            await refreshDisplays()
            if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
                exportPreview(CommandLine.arguments[index + 1])
            }
            if CommandLine.arguments.contains("--audio-smoke") { await audioSmoke() }
            if !CommandLine.arguments.contains("--render-preview"), !CommandLine.arguments.contains("--audio-smoke") {
                enableKeys(prompt: CommandLine.arguments.contains("--request-key-permission") || !defaults.bool(forKey: "keysPermissionPrompted"))
                let targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
                if bluetoothRecovery.pending != nil { _ = resumeBluetoothRoute() }
                else if targets.count > 1 || (targets.first?.volume == nil && !targets.isEmpty) { startSoftwareAudio() }
            }
        }
    }

    deinit {
        timer?.invalidate()
        brightnessTimer?.invalidate()
        audioTask?.cancel()
        for task in displayReadback.values { task.cancel() }
        if let termination { NotificationCenter.default.removeObserver(termination) }
        terminationSignal?.cancel()
        for (target, property, listener) in nativeVolumeListeners + audioRouteListeners {
            var address = property
            _ = AudioObjectRemovePropertyListenerBlock(target, &address, .main, listener)
        }
        for (device, listener) in audioAvailabilityListeners {
            var address = AudioControl.address(kAudioDevicePropertyDeviceIsAlive)
            _ = AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
    }

    func poll() {
        if !keysEnabled { enableKeys(prompt: false) }
        pollAudio()
        writeKeyStatus()
        ticks += 1
        if ticks % 8 == 0 { Task { await refreshDisplays() } }
    }

    func pollAudio() {
        // Start/stop and recovery can refresh again while handling a HAL
        // notification. Let the outer refresh finish the routing decision.
        guard !refreshingAudioRoute, !shuttingDown else { return }
        refreshingAudioRoute = true
        defer { refreshingAudioRoute = false; writeAudioStatus() }
        let previousDefault = defaultID
        let previousOutput = outputs.first(where: { $0.id == previousDefault })
        observeAudioAvailability()
        outputs = audio.outputs(); defaultID = audio.defaultOutput()
        observeNativeVolume()
        // Creating our processing devices also emits device-list changes.
        // The bridge must finish binding before comparing its intended route.
        if audioStarting, systemVolume.deviceID == 0 { return }
        let awaitingRequestedRoute = systemVolume.isWaitingForRoute(defaultID)
        let enteredBluetooth = previousDefault != defaultID || previousOutput?.isBluetooth != true
        if !awaitingRequestedRoute,
           !(softwareAudioRunning || audioStarting) || defaultID != systemVolume.deviceID,
           enteredBluetooth || softwareAudioRunning || audioStarting || groupRunning,
           let headset = outputs.first(where: { $0.id == defaultID && $0.isBluetooth }) {
            rememberBluetoothRoute(headset, previousOutput: previousOutput)
        }
        let usingTemporaryHeadset = bluetoothRecovery.pending != nil
            && outputs.contains(where: { $0.id == defaultID && $0.isBluetooth && !selected.contains($0.uid) })
        if (softwareAudioRunning || audioStarting),
           usingTemporaryHeadset || (systemVolume.deviceID != 0 && defaultID != systemVolume.deviceID && !awaitingRequestedRoute) {
            if bluetoothRecovery.restoring, !usingTemporaryHeadset,
               let current = outputs.first(where: { $0.id == defaultID }), !selected.contains(current.uid) {
                cancelBluetoothRecovery()
            }
            stopSoftwareAudio(clearBluetoothRecovery: false)
            if let output = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) {
                selected = [output.uid]; defaults.set(Array(selected), forKey: "selectedOutputs")
            }
            message = "Sistem ses çıkışı değiştirildi; normal yönlendirmeye dönüldü."
        }
        if (softwareAudioRunning || audioStarting) && softwareAudio.outputUIDs.contains(where: { uid in !outputs.contains(where: { $0.uid == uid }) }) {
            stopSoftwareAudio(clearBluetoothRecovery: false); message = "Ses çıkışı ayrıldı; normal ses yönlendirmesine dönüldü."
        }
        if let id = aggregateID {
            let missing = selected.contains { uid in !outputs.contains { $0.uid == uid } }
            let awaitingGroup = groupTransition?.isPending(current: defaultID) ?? false
            if missing || (defaultID != id && !awaitingGroup) {
                if bluetoothRecovery.restoring, !missing,
                   let current = outputs.first(where: { $0.id == defaultID }), !current.isBluetooth, !selected.contains(current.uid) {
                    cancelBluetoothRecovery()
                }
                stopGroup(clearBluetoothRecovery: false)
                message = missing ? "Bir çıkış ayrıldı. Çoklu çıkış durduruldu ve kullanılabilir çıkışa dönüldü." : "Sistem çıkışı değiştirildi. Unison grubu kapatıldı."
            }
        }
        if bluetoothRecovery.restoring {
            if softwareAudioRunning, systemVolume.deviceID == 0 || defaultID == systemVolume.deviceID { completeBluetoothRecovery() }
            if groupRunning, defaultID == aggregateID { completeBluetoothRecovery() }
        }
        if !softwareAudioRunning, !audioStarting, !groupRunning {
            if bluetoothRecovery.pending != nil,
               let headset = outputs.first(where: { $0.id == defaultID && $0.isBluetooth }) {
                selected = [headset.uid]
                defaults.set(Array(selected), forKey: "selectedOutputs")
            }
            if resumeBluetoothRoute() { return }
        }
        let current = outputs.first(where: { $0.id == defaultID })
        let selection = AudioOutputSelection.followingSystem(current: current, selected: selected,
                                                             managedRouteActive: softwareAudioRunning || audioStarting || groupRunning)
        if selection != selected {
            selected = selection
            defaults.set(Array(selected), forKey: "selectedOutputs")
            if current?.volume == nil, bluetoothRecovery.pending == nil { startSoftwareAudio() }
        }
        if !softwareAudioRunning, !audioStarting, usesNativeVolumeKeys,
           let value = audio.volume(audio.defaultOutput()) {
            syncNativeVolume(value: value, muted: audio.muted(audio.defaultOutput()))
        }
    }

    private func persistBluetoothRecovery() {
        if let route = bluetoothRecovery.pending, let data = try? JSONEncoder().encode(route) {
            defaults.set(data, forKey: "bluetoothAudioRoute")
        } else { defaults.removeObject(forKey: "bluetoothAudioRoute") }
    }

    private func cancelBluetoothRecovery() {
        bluetoothNativeTransition = nil
        guard bluetoothRecovery.pending != nil else { return }
        bluetoothRecovery.cancel()
        persistBluetoothRecovery()
    }

    private func rememberBluetoothRoute(_ headset: Output, previousOutput: Output? = nil) {
        guard headset.isBluetooth else { return }
        if softwareAudioRunning || audioStarting || groupRunning {
            bluetoothRecovery.remember(BluetoothAudioRoute(bluetoothUID: headset.uid, outputUIDs: selected,
                                                         mode: groupRunning ? .group : .software,
                                                         volume: master, muted: masterMuted))
        } else if let current = previousOutput ?? outputs.first(where: { $0.id == defaultID }), current.isAggregate {
            bluetoothRecovery.remember(BluetoothAudioRoute(bluetoothUID: headset.uid,
                                                         outputUIDs: audio.subdeviceUIDs(current.id),
                                                         mode: .device, volume: master, muted: masterMuted,
                                                         deviceUID: current.uid))
        }
        if bluetoothRecovery.pending == nil,
           let speaker = outputs.first(where: { !$0.isAggregate && $0.isBuiltInSpeaker }),
           let route = BluetoothAudioRoute.automatic(bluetoothUID: headset.uid, outputs: outputs,
                                                    volume: speaker.volume ?? master, muted: speaker.muted ?? masterMuted) {
            bluetoothRecovery.remember(route)
        }
        persistBluetoothRecovery()
    }

    private func completeBluetoothRecovery() {
        bluetoothRecovery.complete()
        bluetoothNativeTransition = nil
        persistBluetoothRecovery()
    }

    private func retryBluetoothRecovery() {
        bluetoothRecovery.retry(currentUID: audio.outputs(includeController: true)
            .first(where: { $0.id == audio.defaultOutput() })?.uid)
        bluetoothNativeTransition = nil
        persistBluetoothRecovery()
    }

    @discardableResult private func resumeBluetoothRoute() -> Bool {
        guard bluetoothRecovery.pending != nil, !shuttingDown else { return false }
        if var transition = bluetoothNativeTransition {
            if defaultID == transition.target { completeBluetoothRecovery(); return true }
            if transition.isPending(current: defaultID) { bluetoothNativeTransition = transition; return true }
            retryBluetoothRecovery()
        }
        let previous = bluetoothRecovery.pending
        let current = outputs.first(where: { $0.id == defaultID })
            ?? audio.outputs(includeController: true).first(where: { $0.id == defaultID })
        let restored = bluetoothRecovery.update(current: current, outputs: outputs)
        if previous != bluetoothRecovery.pending { persistBluetoothRecovery() }
        guard let restored else { return false }
        selected = restored.outputUIDs
        master = restored.volume; masterMuted = restored.muted
        defaults.set(Array(selected), forKey: "selectedOutputs")
        defaults.set(master, forKey: "master")
        do {
            // Keep native audio available while the asynchronous engine starts.
            if restored.mode != .device,
               let fallback = outputs.first(where: { selected.contains($0.uid) && $0.isBuiltInSpeaker })
                    ?? outputs.first(where: { selected.contains($0.uid) && !$0.isAggregate }) {
                try audio.setDefault(fallback.id)
            }
            switch restored.mode {
            case .group:
                startGroup(clearBluetoothRecovery: false)
                if !groupRunning { retryBluetoothRecovery() }
            case .software:
                startSoftwareAudio(clearBluetoothRecovery: false)
            case .automatic:
                if selected.count > 1 { startSoftwareAudio(clearBluetoothRecovery: false) }
                else if let speaker = outputs.first(where: { selected.contains($0.uid) }) {
                    let previous = audio.defaultOutput()
                    try audio.setDefault(speaker.id)
                    if speaker.volume != nil { try audio.setLevel(speaker.id, value: master, muted: masterMuted) }
                    bluetoothNativeTransition = AudioRouteTransition(previous: previous, target: speaker.id)
                    if audio.defaultOutput() == speaker.id { completeBluetoothRecovery() }
                    message = "Bluetooth bağlantısı kesildi; Mac hoparlörüne dönüldü."
                }
            case .device:
                if let device = outputs.first(where: { $0.uid == restored.deviceUID }) {
                    let previous = audio.defaultOutput()
                    try audio.setDefault(device.id)
                    bluetoothNativeTransition = AudioRouteTransition(previous: previous, target: device.id)
                    if audio.defaultOutput() == device.id { completeBluetoothRecovery() }
                    message = "Bluetooth bağlantısı kesildi; çoklu çıkışa dönüldü."
                }
            }
        } catch { retryBluetoothRecovery(); message = error.localizedDescription }
        return true
    }

    private func builtInIDs() -> Set<String> {
        NSScreen.screens.compactMap { screen -> String? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, CGDisplayIsBuiltin(number.uint32Value) != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, uuid) as String
        }.reduce(into: Set<String>()) { $0.insert($1.uppercased()) }
    }

    private func syncNativeBrightness() {
        for index in monitors.indices where monitors[index].builtIn {
            guard let value = NativeBrightness.read(monitors[index].displayID), value.isFinite else { continue }
            if abs((monitors[index].brightness ?? -1) - value) > 0.001 {
                monitors[index].brightness = value.clamped
            }
        }
    }

    func refreshDisplays() async {
        guard !busy, !displayWrites.isWriting else { return }
        busy = true
        defer { busy = false }
        do {
            var discovered = try await ddc.discover(builtInIDs: builtInIDs())
            for screen in systemIntegrationEnabled ? NSScreen.screens : [] {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, CGDisplayIsBuiltin(number.uint32Value) != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
                discovered.append(Monitor(id: CFUUIDCreateString(nil, uuid) as String, name: "Yerleşik Retina ekran", brightness: NativeBrightness.read(number.uint32Value), builtIn: true, displayID: number.uint32Value))
            }
            // A drag may have started while discovery was reading old values.
            guard !displayWrites.isWriting else { return }
            for monitor in discovered where !monitor.builtIn && (monitor.brightness != nil || defaults.bool(forKey: "manual.\(monitor.id)")) {
                clearSoftwareBrightness(monitor.id)
            }
            monitors = discovered.map { item in
                var result = item
                result.manual = defaults.bool(forKey: "manual.\(item.id)")
                return result
            }
            shade.prune(available: Set(monitors.map(\.id)))
            // The renderer removes disconnected surfaces. Reapply the retained
            // user level when a software-controlled display is available again.
            for monitor in monitors where !monitor.builtIn && monitor.brightness == nil && !monitor.manual {
                if let brightness = softwareBrightness[monitor.id] { shade.set(monitor.id, brightness: brightness) }
            }
            if !displaySelectionInitialized { selectedDisplays = Set(monitors.map(\.id)); displaySelectionInitialized = true }
        } catch { message = error.localizedDescription }
    }

    func toggleOutput(_ output: Output, enabled: Bool) {
        guard !output.isAggregate else { return }
        cancelBluetoothRecovery()
        if softwareAudioRunning || audioStarting { stopSoftwareAudio() }
        if groupRunning && !stopGroup() { return }
        if enabled { selected.insert(output.uid) } else { selected.remove(output.uid) }
        defaults.set(Array(selected), forKey: "selectedOutputs")
        let targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if targets.count > 1 || (targets.first?.volume == nil && !targets.isEmpty) {
            startSoftwareAudio()
        } else if let target = targets.first {
            routeTo(target)
            if let volume = audio.volume(target.id) { syncNativeVolume(value: volume, muted: audio.muted(target.id)) }
        }
    }
    func setManual(_ id: String, enabled: Bool) {
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        monitors[index].manual = enabled
        defaults.set(enabled, forKey: "manual.\(id)")
        if enabled { clearSoftwareBrightness(id) }
    }
    private func clearSoftwareBrightness(_ id: String) {
        guard softwareBrightness.removeValue(forKey: id) != nil else { return }
        shade.remove(id)
    }
    func setSoftwareBrightness(_ id: String, value: Double) {
        softwareBrightness[id] = max(0.2, value.clamped)
        shade.set(id, brightness: softwareBrightness[id] ?? 1)
    }
    func linkMonitor(_ id: String, enabled: Bool) {
        if enabled { linkedMonitors.insert(id) } else { linkedMonitors.remove(id) }
        defaults.set(Array(linkedMonitors), forKey: "linkedMonitors")
    }
    func setCalibration(_ output: Output, value: Double) {
        calibrations[output.uid] = value.clamped
        defaults.set(calibrations, forKey: "calibrations")
        applyMaster()
    }
    func setMonitorCalibration(_ id: String, value: Double) {
        calibrations["display.\(id)"] = value.clamped
        defaults.set(calibrations, forKey: "calibrations")
        applyMaster()
    }
    func setOutputVolume(_ output: Output, value: Double) {
        if softwareAudioRunning || audioStarting, softwareAudio.outputUIDs.contains(output.uid) {
            deviceGains[output.uid] = value.clamped
            deviceMuted.remove(output.uid)
            updateSoftwareGains()
            return
        }
        if output.volume != nil {
            do {
                try audio.setLevel(output.id, value: value, muted: value > 0 ? false : audio.muted(output.id) ?? false)
                publishNativeLevel(output.id, value: value.clamped, muted: value > 0 ? false : output.muted)
                if usesNativeVolumeKeys, output.id == defaultID {
                    syncNativeVolume(value: value.clamped, muted: value > 0 ? false : output.muted)
                }
            } catch { message = error.localizedDescription }
            return
        }
        do { try audio.setVolume(output.id, value: value); pollAudio() } catch { message = error.localizedDescription }
    }
    func outputMuted(_ output: Output) -> Bool? {
        if softwareAudioRunning || audioStarting, softwareAudio.outputUIDs.contains(output.uid) { return deviceMuted.contains(output.uid) }
        return output.muted
    }
    func toggleMute(_ output: Output) {
        if softwareAudioRunning || audioStarting, softwareAudio.outputUIDs.contains(output.uid) {
            if deviceMuted.contains(output.uid) { deviceMuted.remove(output.uid) } else { deviceMuted.insert(output.uid) }
            updateSoftwareGains()
            return
        }
        do { try audio.setMute(output.id, muted: !(output.muted ?? false)); pollAudio() } catch { message = error.localizedDescription }
    }
    private func observeAudioRouting() {
        guard systemIntegrationEnabled else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var property = AudioControl.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pollAudio() }
            }
            if AudioObjectAddPropertyListenerBlock(system, &property, .main, listener) == noErr {
                audioRouteListeners.append((system, property, listener))
            }
        }
        observeAudioAvailability()
    }

    private func observeAudioAvailability() {
        guard systemIntegrationEnabled else { return }
        // Subscribe before reading availability. HAL can mark a Bluetooth
        // device dead without changing the device list or default yet. Ignore
        // processing aggregates, whose availability changes during start/stop.
        let devices = Set(AudioControl.deviceIDs().filter {
            let kind = AudioControl.transportType($0)
            return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
        })
        for device in Set(audioAvailabilityListeners.keys).subtracting(devices) {
            var property = AudioControl.address(kAudioDevicePropertyDeviceIsAlive)
            if let listener = audioAvailabilityListeners.removeValue(forKey: device) {
                _ = AudioObjectRemovePropertyListenerBlock(device, &property, .main, listener)
            }
        }
        for device in devices where audioAvailabilityListeners[device] == nil {
            var property = AudioControl.address(kAudioDevicePropertyDeviceIsAlive)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pollAudio() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &property, .main, listener) == noErr {
                audioAvailabilityListeners[device] = listener
            }
        }
    }

    private func publishNativeLevel(_ id: AudioDeviceID, value: Double, muted: Bool?) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        let output = outputs[index]
        outputs[index] = Output(id: output.id, uid: output.uid, name: output.name,
                                volume: value, muted: muted, isAggregate: output.isAggregate, transportType: output.transportType)
    }

    private func observeNativeVolume() {
        guard systemIntegrationEnabled else { return }
        guard defaultID != nativeVolumeDevice else { return }
        for (target, property, listener) in nativeVolumeListeners {
            var address = property
            _ = AudioObjectRemovePropertyListenerBlock(target, &address, .main, listener)
        }
        nativeVolumeListeners.removeAll()
        nativeVolumeDevice = defaultID
        let id = defaultID
        guard id != 0 else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for (target, property) in AudioControl.controlTargets(id, selector) {
                var address = property
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.nativeVolumeDevice == id,
                              !self.softwareAudioRunning, !self.audioStarting,
                              let value = self.audio.volume(id) else { return }
                        let muted = self.audio.muted(id)
                        // Our slider writes already published this level. Do
                        // not reinterpret their hardware echo as a new master
                        // value (especially with per-device calibration).
                        if let output = self.outputs.first(where: { $0.id == id }),
                           let displayed = output.volume,
                           abs(displayed - value) < 0.001, output.muted == muted { return }
                        self.publishNativeLevel(id, value: value, muted: muted)
                        if self.usesNativeVolumeKeys { self.syncNativeVolume(value: value, muted: muted) }
                    }
                }
                if AudioObjectAddPropertyListenerBlock(target, &address, .main, listener) == noErr {
                    nativeVolumeListeners.append((target, address, listener))
                }
            }
        }
    }
    func routeTo(_ output: Output) {
        if output.isBluetooth { rememberBluetoothRoute(output) } else { cancelBluetoothRecovery() }
        if softwareAudioRunning || audioStarting { stopSoftwareAudio(clearBluetoothRecovery: false) }
        if groupRunning && !stopGroup(clearBluetoothRecovery: false) { cancelBluetoothRecovery(); return }
        if output.isAggregate {
            let uids = audio.subdeviceUIDs(output.id)
            let members = outputs.filter { uids.contains($0.uid) && !$0.isAggregate }
            if !members.isEmpty {
                selected = Set(members.map(\.uid))
                defaults.set(Array(selected), forKey: "selectedOutputs")
                startSoftwareAudio()
                return
            }
        } else {
            selected = [output.uid]
            defaults.set(Array(selected), forKey: "selectedOutputs")
        }
        do { try audio.setDefault(output.id); pollAudio(); message = "Ses çıkışı: \(output.name)" } catch { message = error.localizedDescription }
    }

    func writeDisplay(_ id: String, feature: String, value: Double) {
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        let readable = feature == "luminance" ? monitors[index].brightness != nil : monitors[index].volume != nil
        // Optimistic feedback only for controls previously confirmed as readable.
        if readable {
            if feature == "luminance" { monitors[index].brightness = value } else { monitors[index].volume = value }
        }
        displayWrites.submit(DisplayControl(id: id, feature: feature), value: value.clamped)
        let key = "\(id).\(feature)"
        displayReadback[key]?.cancel()
        displayReadback[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await displayWrites.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if let observed = try? await ddc.read(id, feature: feature).value, !Task.isCancelled, let index = monitors.firstIndex(where: { $0.id == id }) {
                if feature == "luminance" { monitors[index].brightness = observed } else { monitors[index].volume = observed }
            }
        }
    }

    var hasMasterTargets: Bool {
        softwareAudioRunning || audioStarting || outputs.contains { (selected.contains($0.uid) || (selected.isEmpty && $0.id == defaultID)) && $0.volume != nil } || monitors.contains { linkedMonitors.contains($0.id) && ($0.volume != nil || $0.manual) }
    }
    func applyMaster() {
        defaults.set(master, forKey: "master")
        defer { applyLinkedMonitorVolume() }
        if groupRunning, outputs.contains(where: { selected.contains($0.uid) && !$0.isAggregate && $0.volume == nil }) {
            startSoftwareAudio()
        }
        if softwareAudioRunning || audioStarting {
            do { try systemVolume.write(value: master, muted: masterMuted) } catch { message = error.localizedDescription }
            updateSoftwareGains()
            return
        }
        var unsupported: [String] = []
        for output in outputs where selected.contains(output.uid) || (selected.isEmpty && output.id == defaultID) {
            if output.volume != nil {
                do {
                    let value = (master * (calibrations[output.uid] ?? 1)).clamped
                    try audio.setLevel(output.id, value: value, muted: masterMuted)
                    publishNativeLevel(output.id, value: value, muted: masterMuted)
                } catch { message = error.localizedDescription }
            } else if !monitors.contains(where: { $0.name == output.name && linkedMonitors.contains($0.id) }) { unsupported.append(output.name) }
        }
        if !unsupported.isEmpty { message = "Ortak ses ayarı desteklenmiyor: \(unsupported.joined(separator: ", ")). Monitörü DDC ortak ses grubuna bağlayın." }
    }

    private func applyLinkedMonitorVolume() {
        let targets = monitors.filter { linkedMonitors.contains($0.id) && ($0.volume != nil || $0.manual) }
        let value = masterMuted ? 0 : master
        for target in targets {
            writeDisplay(target.id, feature: "volume", value: value * (calibrations["display.\(target.id)"] ?? 1))
        }
    }

    func startGroup(clearBluetoothRecovery: Bool = true) {
        guard !shuttingDown else { return }
        if clearBluetoothRecovery { cancelBluetoothRecovery() }
        if softwareAudioRunning || audioStarting { stopSoftwareAudio(clearBluetoothRecovery: clearBluetoothRecovery) }
        guard aggregateID == nil else { return }
        let targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        guard targets.count == selected.count, targets.count >= 2 else { message = "En az iki bağlı fiziksel çıkış seçin."; return }
        let previous = audio.defaultOutput()
        originalUID = audio.string(previous, kAudioDevicePropertyDeviceUID)
        do {
            let id = try audio.aggregate(targets)
            aggregateID = id
            defaults.set(originalUID, forKey: "previousOutput")
            defaults.set(audio.string(id, kAudioDevicePropertyDeviceUID), forKey: "ownedAggregate")
            try audio.setDefault(id)
            groupTransition = AudioRouteTransition(previous: previous, target: id)
            groupRunning = true
            pollAudio()
            message = "Çoklu çıkış açık. Bluetooth ile kablolu çıkışlar arasında gecikme olabilir."
        } catch { stopGroup(clearBluetoothRecovery: clearBluetoothRecovery); message = error.localizedDescription }
    }

    @discardableResult func stopGroup(clearBluetoothRecovery: Bool = true) -> Bool {
        if clearBluetoothRecovery { cancelBluetoothRecovery() }
        guard let id = aggregateID else { return true }
        let current = audio.defaultOutput()
        if current == id || (groupTransition?.isPending(current: current) ?? false) {
            let available = audio.outputs().filter { $0.id != id }
            guard let fallback = available.first(where: { $0.uid == originalUID }) ?? available.first(where: { !$0.isAggregate }) else { message = "Dönülecek ses çıkışı bulunamadı; grup korundu."; return false }
            do { try audio.setDefault(fallback.id) } catch { message = error.localizedDescription; return false }
        }
        let status = audio.destroyAggregate(id)
        guard status == noErr else { message = "Grup silinemedi: \(status)"; return false }
        aggregateID = nil; groupRunning = false; groupTransition = nil
        if !clearBluetoothRecovery, !shuttingDown { retryBluetoothRecovery() }
        defaults.removeObject(forKey: "ownedAggregate"); defaults.removeObject(forKey: "previousOutput")
        pollAudio()
        return true
    }

    private func recoverRouting() {
        if let levels = defaults.dictionary(forKey: "unisonNormalizedVolumes") as? [String: Double] {
            let written = defaults.dictionary(forKey: "unisonWrittenNativeVolumes") as? [String: Double] ?? [:]
            for (uid, level) in levels {
                if let output = outputs.first(where: { $0.uid == uid }), let current = audio.volume(output.id), abs(current - (written[uid] ?? 1)) < 0.001 {
                    try? audio.setVolume(output.id, value: level)
                }
            }
            defaults.removeObject(forKey: "unisonNormalizedVolumes")
            defaults.removeObject(forKey: "unisonWrittenNativeVolumes")
        }
        if let mutes = defaults.dictionary(forKey: "unisonNormalizedMutes") as? [String: Bool] {
            let written = defaults.dictionary(forKey: "unisonWrittenNativeMutes") as? [String: Bool] ?? [:]
            for (uid, muted) in mutes {
                if let output = outputs.first(where: { $0.uid == uid }), audio.muted(output.id) == (written[uid] ?? false) {
                    try? audio.setMute(output.id, muted: muted)
                }
            }
            defaults.removeObject(forKey: "unisonNormalizedMutes")
            defaults.removeObject(forKey: "unisonWrittenNativeMutes")
        }
        if audio.string(defaultID, kAudioDevicePropertyDeviceUID) == "org.unison.output" {
            let previous = defaults.string(forKey: "unisonNamedPreviousOutput")
            if let fallback = outputs.first(where: { $0.uid == previous }) ?? outputs.first(where: { !$0.isAggregate }) {
                try? audio.setDefault(fallback.id)
                pollAudio()
            }
        }
        guard let owned = defaults.string(forKey: "ownedAggregate"), let stale = outputs.first(where: { $0.uid == owned }) else { return }
        if defaultID == stale.id {
            guard let fallback = outputs.first(where: { $0.uid == defaults.string(forKey: "previousOutput") }) ?? outputs.first(where: { !$0.isAggregate }) else { return }
            do { try audio.setDefault(fallback.id) } catch { message = error.localizedDescription; return }
        }
        if audio.destroyAggregate(stale.id) == noErr { defaults.removeObject(forKey: "ownedAggregate"); defaults.removeObject(forKey: "previousOutput") }
        pollAudio()
    }

    var usesNativeVolumeKeys: Bool {
        AudioOutputSelection.usesNativeVolumeKeys(currentID: audio.defaultOutput(), outputs: outputs,
                                                 processingAudio: softwareAudioRunning || audioStarting,
                                                 controllerID: systemVolume.deviceID)
    }

    private func syncNativeVolume(value: Double, muted: Bool?) {
        let previous = master
        let previouslyMuted = masterMuted
        let uid = outputs.first(where: { $0.id == audio.defaultOutput() })?.uid ?? ""
        let calibration = (calibrations[uid] ?? 1).clamped
        // The hardware reports the calibrated level. Undo that factor before
        // storing a master, or every poll/mute cycle applies it a second time.
        let common = calibration > 0 ? (value / calibration).clamped : master
        if let muted { master = common; masterMuted = muted }
        // Devices without a mute control use zero volume for mute. Preserve the
        // previous level until a native volume increase or an explicit unmute.
        else if !masterMuted || value > 0 { master = common; masterMuted = false }
        if abs(previous - master) > 0.001 || previouslyMuted != masterMuted {
            defaults.set(master, forKey: "master")
            applyLinkedMonitorVolume()
        }
    }

    func handleVolumeKey(_ key: Int) -> Bool {
        pollAudio()
        guard hasMasterTargets else { return false }
        if !softwareAudioRunning, !audioStarting, selected.count <= 1,
           let current = outputs.first(where: { $0.id == audio.defaultOutput() && (selected.isEmpty || selected.contains($0.uid)) }),
           let value = audio.volume(current.id) {
            syncNativeVolume(value: value, muted: audio.muted(current.id))
        }
        switch key {
        case 0: master = (master + 0.0625).clamped; masterMuted = false
        case 1: master = (master - 0.0625).clamped; masterMuted = false
        case 7: masterMuted.toggle()
        default: return false
        }
        applyMaster()
        return true
    }

    private func writeKeyStatus() {
        guard let index = CommandLine.arguments.firstIndex(of: "--key-status"), CommandLine.arguments.count > index + 1 else { return }
        var text = "accessibility_trusted=\(AXIsProcessTrusted())\nevent_control_allowed=\(CGPreflightPostEventAccess())\nvolume_event_tap_active=\(keysEnabled)\nmaster_targets_available=\(hasMasterTargets)\nsystem_volume_linked=\(systemVolume.deviceID != 0)\nsystem_output_name=\(audio.string(audio.defaultOutput(), kAudioObjectPropertyName))\nnative_volume_keys=\(usesNativeVolumeKeys)\n"
        if let monitor = monitors.first(where: { $0.builtIn }), let value = monitor.brightness {
            text += "built_in_brightness=\(value)\nmaster_brightness=\(masterBrightness)\n"
        }
        try? text.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
    }

    private func writeAudioStatus() {
        guard let index = CommandLine.arguments.firstIndex(of: "--audio-status"), CommandLine.arguments.count > index + 1 else { return }
        let text = "starting=\(audioStarting)\nrunning=\(softwareAudioRunning)\nmaster=\(master)\nmuted=\(masterMuted)\nselected=\(selected.sorted())\nrendered=\(softwareAudio.outputUIDs)\ndevice_gains=\(deviceGains)\ndevice_mutes=\(deviceMuted)\ncontroller=\(systemVolume.uid)\namplitude=\(systemVolume.amplitude)\ncallbacks=\(softwareAudio.callbacks)\ninput_signals=\(softwareAudio.signalBlocks)\ninput_layout=\(softwareAudio.inputLayout)\noutput_layout=\(softwareAudio.outputLayout)\ndelivered=\(softwareAudio.deliveredBlocks)\nsystem_output_uid=\(audio.string(defaultID, kAudioDevicePropertyDeviceUID))\navailable_outputs=\(outputs.map(\.uid).sorted())\nbluetooth_return_uid=\(bluetoothRecovery.pending?.bluetoothUID ?? "")\nbluetooth_return_mode=\(bluetoothRecovery.pending?.mode.rawValue ?? "")\nmessage=\(message)\n"
        try? text.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
    }

    func enableKeys(prompt: Bool = true) {
        guard !keysEnabled else { return }
        // The event tap is the actual capability check. Do not block it using
        // a separate permission preflight that can describe a different state.
        let keys = MediaKeys(nativeVolumeAvailable: { [weak self] in
            // HAL route listeners keep the model current. Enumerating all
            // devices inside the event tap can exceed macOS's tap timeout and
            // interrupt the native key/HUD path while a route is changing.
            self?.usesNativeVolumeKeys ?? false
        }) { [weak self] key in self?.handleVolumeKey(key) ?? false }
        keysEnabled = keys.start()
        if keysEnabled {
            mediaKeys = keys
            writeKeyStatus()
            return
        }
        if prompt {
            defaults.set(true, forKey: "keysPermissionPrompted")
            // Active event filtering uses the Core Graphics event-control grant.
            // AX trust describes Accessibility clients and is not our success criterion.
            _ = CGRequestPostEventAccess()
            keysEnabled = keys.start()
            if keysEnabled { mediaKeys = keys }
            else { message = "Ses tuşu dinleyicisi henüz başlatılamadı. macOS olay denetimi yeniden denenecek." }
        }
        writeKeyStatus()
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled }
        catch { message = error.localizedDescription }
    }

    func startSoftwareAudio(clearBluetoothRecovery: Bool = true) {
        guard !shuttingDown else { return }
        if clearBluetoothRecovery { cancelBluetoothRecovery() }
        guard !audioStarting, !softwareAudioRunning else { return }
        if groupRunning && !stopGroup(clearBluetoothRecovery: clearBluetoothRecovery) { return }
        var targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if targets.isEmpty { targets = outputs.filter { $0.id == defaultID && !$0.isAggregate } }
        if targets.isEmpty { targets = Array(outputs.filter { !$0.isAggregate }.prefix(1)) }
        guard !targets.isEmpty else { retryBluetoothRecovery(); message = "Fiziksel ses çıkışı bulunamadı."; return }
        selected = Set(targets.map(\.uid))
        for target in targets where deviceGains[target.uid] == nil { deviceGains[target.uid] = 1 }
        defaults.set(Array(selected), forKey: "selectedOutputs")
        audioGeneration += 1
        let generation = audioGeneration
        audioStarting = true
        message = "Ses çıkışları hazırlanıyor."
        audioTask = Task { [weak self] in
            do {
                do {
                    guard let self else { return }
                    try await softwareAudio.start(outputs: targets, calibration: calibrations)
                    try Task.checkCancellation()
                    guard audioGeneration == generation, audioStarting else { return }
                    try systemVolume.start(outputs: outputs, value: master, muted: masterMuted) { [weak self] volume, muted in
                        guard let self, audioGeneration == generation, softwareAudioRunning || audioStarting else { return }
                        master = volume; masterMuted = muted
                        defaults.set(master, forKey: "master")
                        updateSoftwareGains(); applyLinkedMonitorVolume(); pollAudio()
                    }
                    message = "Ses akışı bekleniyor. Müzik açın ve macOS'un Unison ses yakalama iznini onaylayın. Doğrulanana kadar normal ses korunur."
                }
                // Release the model while waiting for audio so the task cannot
                // keep a discarded model (and its timers) alive indefinitely.
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self, audioStarting, audioGeneration == generation else { return }
                    if softwareAudio.signalBlocks > 0 {
                        try softwareAudio.activate(master: masterMuted ? 0 : master)
                        audioStarting = false; softwareAudioRunning = true
                        try systemVolume.start(outputs: outputs, value: master, muted: masterMuted, preferNamedOutput: true, renderedUIDs: Set(softwareAudio.outputUIDs)) { [weak self] volume, muted in
                            guard let self, audioGeneration == generation, softwareAudioRunning else { return }
                            master = volume; masterMuted = muted
                            defaults.set(master, forKey: "master")
                            updateSoftwareGains(); applyLinkedMonitorVolume(); pollAudio()
                        }
                        updateSoftwareGains()
                        if bluetoothRecovery.restoring, systemVolume.deviceID == 0 || audio.defaultOutput() == systemVolume.deviceID {
                            completeBluetoothRecovery()
                        }
                        message = "Yazılımsal ses etkin. HDMI sesi sürgülerden kontrol edilebilir."
                        audioTask = nil
                        break
                    }
                }
            } catch {
                guard let self, audioGeneration == generation else { return }
                stopSoftwareAudio(clearBluetoothRecovery: false)
                if !(error is CancellationError) { message = error.localizedDescription }
            }
        }
    }
    private func updateSoftwareGains() {
        guard softwareAudioRunning else { softwareAudio.gain(0); return }
        if systemVolume.uid == "org.unison.output" {
            softwareAudio.gain(masterMuted ? 0 : 1)
            do { try systemVolume.applyNativeLevels(outputs: outputs, master: master, muted: masterMuted, gains: deviceGains, deviceMutes: deviceMuted, calibrations: calibrations) }
            catch { message = error.localizedDescription }
            for uid in softwareAudio.outputUIDs {
                let relative = deviceMuted.contains(uid) ? 0 : deviceGains[uid] ?? 1
                let gain = NamedOutputGain.device(master: master, relative: relative, calibration: calibrations[uid] ?? 1, hardwareControlled: systemVolume.controlsNativeLevel(uid), muted: masterMuted)
                softwareAudio.deviceGain(uid, value: gain)
            }
        } else if systemVolume.deviceID == 0 {
            softwareAudio.gain(masterMuted ? 0 : master)
            for uid in softwareAudio.outputUIDs { softwareAudio.deviceGain(uid, value: deviceMuted.contains(uid) ? 0 : (deviceGains[uid] ?? 1) * (calibrations[uid] ?? 1)) }
        } else {
            softwareAudio.gain(masterMuted ? 0 : 1)
            for uid in softwareAudio.outputUIDs {
                softwareAudio.deviceGain(uid, value: LinkedVolumeGain.device(master: master, relative: deviceMuted.contains(uid) ? 0 : deviceGains[uid] ?? 1, calibration: calibrations[uid] ?? 1, isSystemDevice: uid == systemVolume.uid, muted: masterMuted, systemAmplitude: systemVolume.amplitude))
            }
        }
    }
    func stopSoftwareAudio(clearBluetoothRecovery: Bool = true) {
        if clearBluetoothRecovery { cancelBluetoothRecovery() }
        audioGeneration += 1
        audioTask?.cancel(); audioTask = nil
        audioStarting = false
        systemVolume.stop(); softwareAudio.stop()
        softwareAudioRunning = false
        if !clearBluetoothRecovery, !shuttingDown { retryBluetoothRecovery() }
    }

    @discardableResult func prepareForTermination() -> Bool {
        shuttingDown = true
        stopSoftwareAudio(clearBluetoothRecovery: false)
        guard stopGroup(clearBluetoothRecovery: false) else { shuttingDown = false; return false }
        shade.reset()
        return true
    }

    func outputValue(_ output: Output) -> Double? {
        if softwareAudioRunning || audioStarting, softwareAudio.outputUIDs.contains(output.uid) { return deviceMuted.contains(output.uid) ? 0 : deviceGains[output.uid] ?? 1 }
        return output.volume
    }
    func toggleDisplay(_ id: String) {
        if selectedDisplays.contains(id) { selectedDisplays.remove(id) } else { selectedDisplays.insert(id) }
        defaults.set(Array(selectedDisplays), forKey: "selectedDisplays")
    }
    func brightnessValue(_ monitor: Monitor) -> Double { monitor.brightness ?? softwareBrightness[monitor.id] ?? 1 }
    func setBrightness(_ monitor: Monitor, value: Double) {
        setBrightness(monitor, value: value, updateShared: true)
    }
    private func setBrightness(_ monitor: Monitor, value: Double, updateShared: Bool) {
        if monitor.builtIn {
            do {
                try NativeBrightness.write(monitor.displayID, value: value)
                if let index = monitors.firstIndex(where: { $0.id == monitor.id }) { monitors[index].brightness = NativeBrightness.read(monitor.displayID) }
            } catch { message = error.localizedDescription }
        } else if monitor.brightness != nil || monitor.manual {
            clearSoftwareBrightness(monitor.id)
            writeDisplay(monitor.id, feature: "luminance", value: value)
        }
        else { setSoftwareBrightness(monitor.id, value: value) }
        // Only an explicit device-slider edit updates the shared indicator.
        // Native F1/F2 polling deliberately remains independent.
        if updateShared, selectedDisplays.contains(monitor.id) {
            let targets = monitors.filter { selectedDisplays.contains($0.id) }
            if !targets.isEmpty {
                masterBrightness = targets.reduce(0) { total, target in
                    total + (target.id == monitor.id ? value.clamped : brightnessValue(target))
                } / Double(targets.count)
            }
        }
    }
    func applyBrightness(_ value: Double) {
        masterBrightness = value.clamped
        for monitor in monitors where selectedDisplays.contains(monitor.id) { setBrightness(monitor, value: value, updateShared: false) }
    }

    private func exportPreview(_ path: String) {
        // Render our own SwiftUI view as an artifact, without taking a desktop screenshot.
        let panel = ControlPanel(model: self, showingDisplays: CommandLine.arguments.contains("--preview-displays"), expandedDetails: CommandLine.arguments.contains("--preview-details"))
        let content = CommandLine.arguments.contains("--preview-settings") ? AnyView(panel.settingsPanel) : AnyView(panel)
        let view = NSHostingView(rootView: content.environment(\.unisonPreviewReduceMotion, CommandLine.arguments.contains("--preview-reduced-motion")))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)); print("Arayüz önizlemesi: \(path)") }
        }
        NSApp.terminate(nil)
    }

    private func testAmplitudes(expected: [Double]) async throws -> (Double, [Double]) {
        var input = 0.0
        var output: [Double] = []
        let ready = try await AudioReadiness.wait(timeout: .seconds(2)) {
            input = self.softwareAudio.inputPeak
            output = self.softwareAudio.outputPeaks
            let tonePeak = 1600.0 / 32768.0
            return abs(input - tonePeak) < 0.002 && output.count == expected.count && zip(output, expected).allSatisfy { abs($0.0 / input - $0.1) < 0.015 }
        }
        guard ready else { throw ControlError.message("Test sesinin genliği beklenen düzeye ulaşmadı: giriş=\(input), çıkış=\(output), oran=\(expected).") }
        return (input, output)
    }
    private func audioSmoke() async {
        let previous = audio.defaultOutput()
        let savedSelection = defaults.stringArray(forKey: "selectedOutputs")
        let savedMaster = defaults.object(forKey: "master")
        let priorMaster = master
        let priorMuted = masterMuted
        let physical = outputs.filter { !$0.isAggregate && ($0.name == "VG249Q3A" || $0.name.localizedCaseInsensitiveContains("MacBook")) }
        var report: [String] = ["accessibility_trusted=\(AXIsProcessTrusted())"]
        let speaker = physical.first { $0.volume != nil }
        let originalVolume = speaker.flatMap { audio.volume($0.id) }
        let originalMute = speaker.flatMap { audio.muted($0.id) }
        var sound: Process?
        do {
            guard physical.count >= 2 else { throw ControlError.message("İki fiziksel çıkış gerekli.") }
            report.append("physical_outputs=\(physical.map(\.name))")
            if let speaker, let originalVolume {
                // Exercise the same native path used by the MacBook row.
                routeTo(speaker)
                setOutputVolume(speaker, value: max(0.1, originalVolume * 0.8))
                let observed = audio.volume(speaker.id) ?? -1
                let expected = max(0.1, originalVolume * 0.8)
                guard abs(observed - expected) < 0.01, audio.defaultOutput() == speaker.id else { throw ControlError.message("MacBook yönlendirme/ses geri okuması başarısız.") }
                guard abs(master - expected) < 0.01,
                      abs((outputs.first(where: { $0.id == speaker.id })?.volume ?? -1) - expected) < 0.01 else {
                    throw ControlError.message("Cihaz sürgüsü ortak sesi aynı işlemde güncellemedi.")
                }
                report.append("macbook_native_volume_and_route=PASS")
                master = 0.35; masterMuted = false; applyMaster()
                masterMuted = true; applyMaster(); poll()
                guard masterMuted, abs(master - 0.35) < 0.01, audio.muted(speaker.id) == true else {
                    throw ControlError.message("Ortak sessize alma, kayıtlı ses seviyesini korumadı.")
                }
                master = 0.4; masterMuted = false; applyMaster()
                guard abs((outputs.first(where: { $0.id == speaker.id })?.volume ?? -1) - 0.4) < 0.01 else {
                    throw ControlError.message("Ortak sürgü cihaz seviyesini aynı işlemde güncellemedi.")
                }
                guard audio.muted(speaker.id) == false, abs((audio.volume(speaker.id) ?? -1) - 0.4) < 0.01 else {
                    throw ControlError.message("Ortak ses sürgüsü donanım sessizliğini kaldırmadı.")
                }
                report.append("native_master_mute_poll_and_unmute=PASS")
                try audio.setLevel(speaker.id, value: 0.45, muted: false)
                let notificationDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                while abs(master - 0.45) > 0.01, ContinuousClock.now < notificationDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard abs(master - 0.45) < 0.01,
                      abs((outputs.first(where: { $0.id == speaker.id })?.volume ?? -1) - 0.45) < 0.01 else {
                    throw ControlError.message("Sistem ses bildirimi iki saniyelik taramayı beklemeden yansımadı.")
                }
                report.append("native_slider_immediate_sync_and_notification=PASS")
                master = 0.4; applyMaster()

            }
            if CommandLine.arguments.contains("--keep-route") {
                try audio.setDefault(previous)
                let deadline = Date().addingTimeInterval(2)
                while audio.defaultOutput() != previous && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            if CommandLine.arguments.contains("--selection-smoke"), let speaker {
                routeTo(speaker)
                let routeDeadline = Date().addingTimeInterval(2)
                while audio.defaultOutput() != speaker.id && Date() < routeDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                guard audio.defaultOutput() == speaker.id else { throw ControlError.message("Ses testi için yerleşik yönlendirme tamamlanmadı.") }
                pollAudio()
                master = 0.5; masterMuted = false
                for output in physical where output.uid != speaker.uid { toggleOutput(output, enabled: true) }
                guard audioStarting else { throw ControlError.message("Seçim çoklu ses motorunu başlatmadı.") }
                // An immediate stop/restart must retire the queued startup,
                // without its cleanup later destroying the replacement session.
                stopSoftwareAudio()
                startSoftwareAudio()
                let startupDeadline = Date().addingTimeInterval(2)
                while audioStarting && systemVolume.deviceID == 0 && Date() < startupDeadline { try await Task.sleep(for: .milliseconds(20)) }
                guard audioStarting, softwareAudio.isRunning, systemVolume.deviceID != 0 else { throw ControlError.message("Asenkron ses başlatma tamamlanmadı: \(message)") }
                report.append("cancel_and_restart_pending_audio=PASS")
                _ = handleVolumeKey(1)
                guard abs((audio.volume(speaker.id) ?? -1) - master) < 0.01 else { throw ControlError.message("Ses beklenirken sistem seviyesi güncellenmedi.") }
                _ = handleVolumeKey(0)
                report.append("control_center_volume_while_waiting=PASS")
            } else {
                try await softwareAudio.start(outputs: physical, calibration: [:])
            }
            let source = Process()
            let sourceLog = Pipe()
            source.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            source.arguments = ["/tmp/unison-test-tone.wav"]
            source.standardOutput = sourceLog; source.standardError = sourceLog
            try source.run(); sound = source
            let sourceStarted = Date()
            let deadline = sourceStarted.addingTimeInterval(5)
            while softwareAudio.signalBlocks == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            guard softwareAudio.signalBlocks > 0 else {
                let log = source.isRunning ? "çalışıyor" : String(data: sourceLog.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ControlError.message("Ses kaynağı alınamadı: callback=\(softwareAudio.callbacks), giriş=\(softwareAudio.inputLayout), motor=\(softwareAudio.isRunning), bekleniyor=\(audioStarting), varsayılan=\(audio.defaultOutput()), denetleyici=\(systemVolume.deviceID), durum=\(message), kaynak=\(source.isRunning), kayıt=\(log).")
            }
            report.append("first_input_after_ms=\(Int(Date().timeIntervalSince(sourceStarted) * 1000))")
            report.append("before_activation_layout=\(softwareAudio.outputLayout)")
            if CommandLine.arguments.contains("--selection-smoke") {
                let activationDeadline = Date().addingTimeInterval(2)
                while audioStarting && Date() < activationDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                guard softwareAudioRunning else { throw ControlError.message("Seçimden başlatılan motor etkinleşmedi.") }
                report.append("selection_starts_multi_output=PASS")
            } else { try softwareAudio.activate(master: 0.5) }
            try? await Task.sleep(for: .milliseconds(400))
            // Native routes settle asynchronously. Verify forwarding readiness
            // within a bounded deadline instead of assuming a fixed 400 ms.
            let forwardingDeadline = Date().addingTimeInterval(2)
            while softwareAudio.deliveredBlocks.contains(0) && Date() < forwardingDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            report.append("input_signals_after_activation=\(softwareAudio.signalBlocks)")
            report.append("forwarding_ready_after_ms=\(Int(Date().timeIntervalSince(sourceStarted) * 1000))")
            let both = softwareAudio.deliveredBlocks
            report.append("output_layout=\(softwareAudio.outputLayout >> 16)buffers/\(softwareAudio.outputLayout & 0xffff)channels")
            report.append("output_signal_blocks=\(both)")
            guard both.count == physical.count, both.allSatisfy({ $0 > 0 }) else {
                throw ControlError.message("Çıkışlara ses yazılmadı: callback=\(softwareAudio.callbacks), motor=\(softwareAudio.isRunning), varsayılan=\(audio.defaultOutput()), denetleyici=\(systemVolume.deviceID), ortak ses=\(master), sistem seviyesi=\(audio.volume(systemVolume.deviceID) ?? -1), sistem kazancı=\(systemVolume.amplitude), sistem sessiz=\(audio.muted(systemVolume.deviceID).map(String.init) ?? "yok"), sessiz=\(masterMuted), durum=\(message), kaynak=\(source.isRunning).")
            }
            report.append("both_outputs=PASS")
            var processAddress = AudioControl.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var sourcePID = source.processIdentifier, sourceID: AudioObjectID = 0, processSize: UInt32 = 4
            try AudioControl.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, 4, &sourcePID, &processSize, &sourceID))
            try softwareAudio.isolateCapture(processID: sourceID)
            for level in [0.66, 1.0] {
                master = level; masterMuted = false; applyMaster()
                let (input, outputPeaks) = try await testAmplitudes(expected: physical.map { $0.volume != nil ? 1 : level })
                report.append("amplitude_\(level): input=\(input) outputs=\(outputPeaks) control=\(systemVolume.amplitude)")
                for output in physical {
                    if output.volume != nil, abs((audio.volume(output.id) ?? -1) - level) > 0.01 {
                        throw ControlError.message("\(output.name) yerel ses seviyesi çoklu çıkışta değişti.")
                    }
                }
            }
            report.append("native_volume_parity_and_hdmi_linear_gain=PASS")
            master = 0.5; applyMaster()
            if softwareAudioRunning, let speaker {
                let systemControlID = systemVolume.deviceID
                let nativeBefore = audio.volume(systemControlID)
                guard systemControlID == speaker.id || systemVolume.uid == "org.unison.output" else { throw ControlError.message("Sistem ses denetimi bağlanmadı.") }
                let masterBefore = master
                busy = true
                let downHandled = handleVolumeKey(1)
                let lowered = master
                let systemLowered = audio.volume(systemControlID) ?? -1
                let upHandled = handleVolumeKey(0)
                busy = false
                guard downHandled, upHandled, abs(lowered - (masterBefore - 0.0625)) < 0.001,
                      abs(master - masterBefore) < 0.001, abs(systemLowered - lowered) < 0.01, abs((audio.volume(systemControlID) ?? -1) - (nativeBefore ?? -2)) < 0.01 else {
                    throw ControlError.message("Ortak ses tuşu denetimi başarısız.")
                }
                guard handleVolumeKey(7) else { throw ControlError.message("Sessiz tuşu işlenmedi.") }
                try? await Task.sleep(for: .milliseconds(100))
                let keyMuteBefore = softwareAudio.deliveredBlocks
                try? await Task.sleep(for: .milliseconds(150))
                guard softwareAudio.deliveredBlocks == keyMuteBefore else { throw ControlError.message("Ses tuşu tüm çıkışları susturmadı.") }
                _ = handleVolumeKey(7)
                report.append("volume_keys_common_gain_and_mute=PASS")
                try audio.setVolume(systemControlID, value: 0.375)
                try? await Task.sleep(for: .milliseconds(100))
                guard abs(master - 0.375) < 0.01 else { throw ControlError.message("Sistem sürgüsü ortak sese geri yansımadı.") }
                report.append("control_center_volume_bidirectional=PASS")
                report.append("system_output_name=\(audio.string(audio.defaultOutput(), kAudioObjectPropertyName))")
                master = masterBefore; applyMaster()
            }
            let commonBeforeRow = master
            setOutputVolume(physical[1], value: 0)
            guard abs(master - commonBeforeRow) < 0.001 else { throw ControlError.message("Cihaz sürgüsü ortak sesi değiştirdi.") }
            try? await Task.sleep(for: .milliseconds(100))
            let isolatedBefore = softwareAudio.deliveredBlocks
            try? await Task.sleep(for: .milliseconds(300))
            let isolatedAfter = softwareAudio.deliveredBlocks
            guard isolatedAfter[0] > isolatedBefore[0], isolatedAfter[1] == isolatedBefore[1] else { throw ControlError.message("Bağımsız cihaz kazancı başarısız.") }
            report.append("independent_device_mute=PASS")
            softwareAudio.gain(0)
            try? await Task.sleep(for: .milliseconds(100))
            let muteBefore = softwareAudio.deliveredBlocks
            try? await Task.sleep(for: .milliseconds(250))
            guard softwareAudio.deliveredBlocks == muteBefore else { throw ControlError.message("Ortak sessize alma başarısız.") }
            report.append("master_mute=PASS")
            if let speaker, let hdmi = physical.first(where: { $0.volume == nil }) {
                master = 0.66
                masterMuted = false
                deviceGains[speaker.uid] = 1
                applyMaster()
                for pass in 1...2 {
                    toggleOutput(speaker, enabled: false)
                    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while (!softwareAudioRunning || softwareAudio.deliveredBlocks.first ?? 0 == 0), ContinuousClock.now < readyDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard softwareAudioRunning, selected == [hdmi.uid],
                          softwareAudio.outputUIDs == [hdmi.uid], softwareAudio.deliveredBlocks.first ?? 0 > 0 else {
                        throw ControlError.message("Çoklu çıkıştan tek HDMI geçişi başarısız: tur=\(pass), seçim=\(selected), render=\(softwareAudio.outputUIDs), callback=\(softwareAudio.callbacks), giriş=\(softwareAudio.signalBlocks), çıkış=\(softwareAudio.deliveredBlocks), durum=\(message).")
                    }
                    let deliveredBefore = softwareAudio.deliveredBlocks[0]
                    // The first block can precede a brief HAL routing pause.
                    // Require continued delivery within a bounded readiness window.
                    let continues = try await AudioReadiness.wait(timeout: .seconds(2)) {
                        self.softwareAudio.deliveredBlocks.first ?? 0 > deliveredBefore
                    }
                    guard continues else {
                        throw ControlError.message("Tek HDMI akışı geçişten sonra durdu.")
                    }
                    try softwareAudio.isolateCapture(processID: sourceID)
                    let (input, output) = try await testAmplitudes(expected: [master])
                    report.append("single_hdmi_gain_\(pass)=\(output[0] / input)")
                    report.append("multi_to_single_hdmi_\(pass)=PASS")
                    toggleOutput(speaker, enabled: true)
                    let multiDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while (!softwareAudioRunning || softwareAudio.deliveredBlocks.contains(0)), ContinuousClock.now < multiDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard softwareAudioRunning, softwareAudio.deliveredBlocks.count == 2,
                          softwareAudio.deliveredBlocks.allSatisfy({ $0 > 0 }) else {
                        throw ControlError.message("Tek HDMI çıkışından çoklu çıkışa dönüş başarısız.")
                    }
                    report.append("single_hdmi_to_multi_\(pass)=PASS")
                }
            }
            if CommandLine.arguments.contains("--selection-smoke"), let speaker {
                stopSoftwareAudio()
                routeTo(speaker)
                let nativeDeadline = Date().addingTimeInterval(2)
                while audio.defaultOutput() != speaker.id && Date() < nativeDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                pollAudio()
                // Simulate the state after a temporary headset disappears, then
                // verify the automatic return renders to the actual hardware.
                let departedHeadset = Output(id: 0, uid: "unison-smoke-headset", name: "Test Headset", volume: 0.8, muted: false,
                                              isAggregate: false, transportType: kAudioDeviceTransportTypeBluetooth)
                rememberBluetoothRoute(departedHeadset)
                guard bluetoothRecovery.pending?.mode == .automatic else {
                    throw ControlError.message("Tek Mac çıkışından Bluetooth dönüşü kaydedilmedi.")
                }
                // Repeated early fallback reads must not discard the return.
                for _ in 0..<20 {
                    guard bluetoothRecovery.update(current: speaker, outputs: outputs + [departedHeadset]) == nil,
                          bluetoothRecovery.pending != nil else {
                        throw ControlError.message("Gecikmeli Bluetooth kopuşu otomatik dönüşü iptal etti.")
                    }
                }
                // Exercise the missing-default path without changing Bluetooth
                // settings or invalidating the real hardware's system default.
                defaultID = 0
                guard resumeBluetoothRoute() else {
                    throw ControlError.message("Varsayılan çıkış boşken Bluetooth dönüşü başlamadı.")
                }
                let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while (!softwareAudioRunning || softwareAudio.deliveredBlocks.contains(0)), ContinuousClock.now < recoveryDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard softwareAudioRunning, selected == Set(physical.map(\.uid)),
                      Set(softwareAudio.outputUIDs) == selected,
                      softwareAudio.deliveredBlocks.count == physical.count,
                      softwareAudio.deliveredBlocks.allSatisfy({ $0 > 0 }), bluetoothRecovery.pending == nil else {
                    throw ControlError.message("Bluetooth dönüşü Mac ve HDMI'ya ses göndermedi: seçim=\(selected), render=\(softwareAudio.outputUIDs), durum=\(message).")
                }
                report.append("simulated_bluetooth_disconnect_live_multi_output=PASS")
                report.append("simulated_delayed_bluetooth_disconnect_missing_default=PASS")
            }
            // Complete forwarding checks before exercising Bluetooth route
            // changes; a user route change intentionally stops forwarding.
            if let speaker {
                if source.isRunning { source.terminate() }
                stopSoftwareAudio()
                routeTo(speaker)
                let routeDeadline = Date().addingTimeInterval(2)
                while audio.defaultOutput() != speaker.id && Date() < routeDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                pollAudio()
                if let other = outputs.first(where: { $0.id == previous && !$0.isAggregate && $0.volume != nil && $0.id != speaker.id }) {
                    try audio.setDefault(other.id)
                    let switchDeadline = Date().addingTimeInterval(2)
                    while audio.defaultOutput() != other.id && Date() < switchDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                    pollAudio()
                    guard selected == [other.uid], usesNativeVolumeKeys, abs(master - (audio.volume(other.id) ?? -1)) < 0.01 else {
                        throw ControlError.message("Cihaz yenilemesi ses tuşlarını etkin çıkışa bağlamadı.")
                    }
                    poll()
                    guard selected == [other.uid], usesNativeVolumeKeys, abs(master - (audio.volume(other.id) ?? -1)) < 0.01 else {
                        throw ControlError.message("Sistem çıkışı değişimi: seçim=\(selected), varsayılan=\(defaultID), gerçek=\(audio.defaultOutput()), beklenen=\(other.id), ortak ses=\(master), gerçek ses=\(audio.volume(other.id) ?? -1), yerel tuşlar=\(usesNativeVolumeKeys).")
                    }
                    report.append("native_output_switch_follows_system=PASS")
                }
                try audio.setVolume(speaker.id, value: 0.4)
                if audio.outputs(includeController: true).contains(where: { $0.uid == "org.unison.output" }) {
                    try audio.setMute(speaker.id, muted: true)
                    let bridgePrevious = audio.defaultOutput()
                    do {
                        let bridge = SystemVolumeBridge()
                        defer { bridge.stop() }
                        try bridge.start(outputs: physical, value: 0.4, muted: false, preferNamedOutput: true, renderedUIDs: [speaker.uid]) { _, _ in }
                        try bridge.applyNativeLevels(outputs: physical, master: 0.6, muted: false, gains: [:], deviceMutes: [], calibrations: [:])
                        guard audio.muted(speaker.id) == false, abs((audio.volume(speaker.id) ?? -1) - 0.6) < 0.01 else {
                            throw ControlError.message("Yazılımsal çıkışın donanım sessizliği kaldırılmadı.")
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    guard audio.muted(speaker.id) == true, abs((audio.volume(speaker.id) ?? -1) - 0.4) < 0.01,
                          audio.defaultOutput() == bridgePrevious else {
                        throw ControlError.message("Yazılımsal çıkış geri yüklemesi: ses=\(audio.volume(speaker.id) ?? -1), sessiz=\(audio.muted(speaker.id).map(String.init) ?? "yok"), çıkış=\(audio.defaultOutput()), beklenen=\(bridgePrevious).")
                    }
                    try audio.setMute(speaker.id, muted: false)
                    report.append("native_hardware_level_mute_and_restore=PASS")
                }
            }
        } catch { report.append("ERROR=\(error.localizedDescription)") }
        if let sound, sound.isRunning { sound.terminate() }
        stopSoftwareAudio()
        if let speaker, let originalVolume { try? audio.setVolume(speaker.id, value: originalVolume) }
        if let speaker, let originalMute { try? audio.setMute(speaker.id, muted: originalMute) }
        try? audio.setDefault(previous)
        let restoreDeadline = Date().addingTimeInterval(2)
        while audio.defaultOutput() != previous && Date() < restoreDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        master = priorMaster; masterMuted = priorMuted
        if let savedSelection { defaults.set(savedSelection, forKey: "selectedOutputs") } else { defaults.removeObject(forKey: "selectedOutputs") }
        if let savedMaster { defaults.set(savedMaster, forKey: "master") } else { defaults.removeObject(forKey: "master") }
        report.append("previous_route_restored=\(audio.defaultOutput() == previous)")
        if audio.defaultOutput() != previous { report.append("ERROR=Önceki sistem çıkışı geri yüklenemedi.") }
        let text = report.joined(separator: "\n") + "\n"
        print(text)
        if let i = CommandLine.arguments.firstIndex(of: "--smoke-report"), CommandLine.arguments.count > i + 1 {
            try? text.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}

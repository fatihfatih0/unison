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
    private let softwareAudio = SoftwareAudio()
    private let systemVolume = SystemVolumeBridge()
    private let ddc = DDC()
    private let shade = ScreenShade()
    private var timer: Timer?
    private var brightnessTimer: Timer?
    private var ticks = 0
    private var displaySelectionInitialized = false
    private var aggregateID: AudioDeviceID?
    private var originalUID: String?
    private let defaults = UserDefaults.standard
    private var mediaKeys: MediaKeys?
    private var termination: NSObjectProtocol?
    private var terminationSignal: DispatchSourceSignal?
    private var audioGeneration = 0
    private var audioTask: Task<Void, Never>?
    private struct DisplayControl: Hashable { let id: String; let feature: String }
    private var displayReadback: [String: Task<Void, Never>] = [:]
    private lazy var displayWrites = LatestValueQueue<DisplayControl> { [weak self] target, value in
        guard let self, let monitor = monitors.first(where: { $0.id == target.id }) else { return }
        do {
            try await ddc.send(target.id, feature: target.feature, value: value, max: target.feature == "luminance" ? monitor.brightnessMax : monitor.volumeMax)
        } catch { message = error.localizedDescription }
    }

    init() {
        selected = Set(defaults.stringArray(forKey: "selectedOutputs") ?? [])
        if let saved = defaults.stringArray(forKey: "selectedDisplays") { selectedDisplays = Set(saved); displaySelectionInitialized = true }
        linkedMonitors = Set(defaults.stringArray(forKey: "linkedMonitors") ?? [])
        calibrations = defaults.dictionary(forKey: "calibrations") as? [String: Double] ?? [:]
        if defaults.object(forKey: "master") != nil { master = defaults.double(forKey: "master").clamped }
        outputs = AudioControl.outputs(); defaultID = AudioControl.defaultOutput()
        if selected.isEmpty, let current = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) { selected.insert(current.uid) }
        recoverRouting()
        let savedTargets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if selected.count <= 1, savedTargets.allSatisfy({ $0.volume != nil }),
           let current = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) {
            selected = [current.uid]
            defaults.set(Array(selected), forKey: "selectedOutputs")
            if let value = AudioControl.volume(current.id) { master = value; masterMuted = AudioControl.muted(current.id) ?? false }
        }
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSoftwareAudio(); _ = self?.stopGroup(); self?.shade.reset() }
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
                if targets.count > 1 || (targets.first?.volume == nil && !targets.isEmpty) { startSoftwareAudio() }
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
    }

    func poll() {
        if !keysEnabled { enableKeys(prompt: false) }
        writeKeyStatus()
        let previousDefault = defaultID
        outputs = AudioControl.outputs(); defaultID = AudioControl.defaultOutput()
        if (softwareAudioRunning || audioStarting), systemVolume.deviceID != 0, defaultID != systemVolume.deviceID {
            stopSoftwareAudio()
            if let output = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) {
                selected = [output.uid]; defaults.set(Array(selected), forKey: "selectedOutputs")
            }
            message = "Sistem ses çıkışı değiştirildi; normal yönlendirmeye dönüldü."
        }
        if (softwareAudioRunning || audioStarting) && softwareAudio.outputUIDs.contains(where: { uid in !outputs.contains(where: { $0.uid == uid }) }) {
            stopSoftwareAudio(); message = "Ses çıkışı ayrıldı; normal ses yönlendirmesine dönüldü."
        }
        if let id = aggregateID {
            let missing = selected.contains { uid in !outputs.contains { $0.uid == uid } }
            if missing || defaultID != id {
                stopGroup()
                message = missing ? "Bir çıkış ayrıldı. Çoklu çıkış durduruldu ve kullanılabilir çıkışa dönüldü." : "Sistem çıkışı değiştirildi. Unison grubu kapatıldı."
            }
        }
        if !softwareAudioRunning, !audioStarting, !groupRunning, selected.count <= 1,
           defaultID != previousDefault, let output = outputs.first(where: { $0.id == defaultID && !$0.isAggregate }) {
            selected = [output.uid]
            defaults.set(Array(selected), forKey: "selectedOutputs")
            if output.volume == nil { startSoftwareAudio() }
        }
        if !softwareAudioRunning, !audioStarting, usesNativeVolumeKeys,
           let value = AudioControl.volume(AudioControl.defaultOutput()) {
            syncNativeVolume(value: value, muted: AudioControl.muted(AudioControl.defaultOutput()))
        }
        ticks += 1
        if ticks % 8 == 0 { Task { await refreshDisplays() } }
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
            for screen in NSScreen.screens {
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
            if !displaySelectionInitialized { selectedDisplays = Set(monitors.map(\.id)); displaySelectionInitialized = true }
        } catch { message = error.localizedDescription }
    }

    func toggleOutput(_ output: Output, enabled: Bool) {
        guard !output.isAggregate else { return }
        if softwareAudioRunning || audioStarting { stopSoftwareAudio() }
        if groupRunning && !stopGroup() { return }
        if enabled { selected.insert(output.uid) } else { selected.remove(output.uid) }
        defaults.set(Array(selected), forKey: "selectedOutputs")
        let targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if targets.count > 1 || (targets.first?.volume == nil && !targets.isEmpty) {
            startSoftwareAudio()
        } else if let target = targets.first {
            routeTo(target)
            if let volume = AudioControl.volume(target.id) { master = volume }
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
                try AudioControl.setLevel(output.id, value: value, muted: value > 0 ? false : AudioControl.muted(output.id) ?? false)
                pollAudio()
            } catch { message = error.localizedDescription }
            return
        }
        do { try AudioControl.setVolume(output.id, value: value); pollAudio() } catch { message = error.localizedDescription }
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
        do { try AudioControl.setMute(output.id, muted: !(output.muted ?? false)); pollAudio() } catch { message = error.localizedDescription }
    }
    func pollAudio() { outputs = AudioControl.outputs(); defaultID = AudioControl.defaultOutput() }
    func routeTo(_ output: Output) {
        if softwareAudioRunning || audioStarting { stopSoftwareAudio() }
        if groupRunning && !stopGroup() { return }
        if output.isAggregate {
            let uids = AudioControl.subdeviceUIDs(output.id)
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
        do { try AudioControl.setDefault(output.id); pollAudio(); message = "Ses çıkışı: \(output.name)" } catch { message = error.localizedDescription }
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
                do { try AudioControl.setLevel(output.id, value: master * (calibrations[output.uid] ?? 1), muted: masterMuted) } catch { message = error.localizedDescription }
            } else if !monitors.contains(where: { $0.name == output.name && linkedMonitors.contains($0.id) }) { unsupported.append(output.name) }
        }
        let targets = monitors.filter { linkedMonitors.contains($0.id) && ($0.volume != nil || $0.manual) }
        if !unsupported.isEmpty { message = "Ortak ses ayarı desteklenmiyor: \(unsupported.joined(separator: ", ")). Monitörü DDC ortak ses grubuna bağlayın." }
        let value = masterMuted ? 0 : master
        for target in targets {
            writeDisplay(target.id, feature: "volume", value: value * (calibrations["display.\(target.id)"] ?? 1))
        }
        pollAudio()
    }

    func startGroup() {
        if softwareAudioRunning || audioStarting { stopSoftwareAudio() }
        guard aggregateID == nil else { return }
        let targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        guard targets.count == selected.count, targets.count >= 2 else { message = "En az iki bağlı fiziksel çıkış seçin."; return }
        let previous = AudioControl.defaultOutput()
        originalUID = AudioControl.string(previous, kAudioDevicePropertyDeviceUID)
        do {
            let id = try AudioControl.aggregate(targets)
            aggregateID = id
            defaults.set(originalUID, forKey: "previousOutput")
            defaults.set(AudioControl.string(id, kAudioDevicePropertyDeviceUID), forKey: "ownedAggregate")
            try AudioControl.setDefault(id)
            groupRunning = true
            pollAudio()
            message = "Çoklu çıkış açık. Bluetooth ile kablolu çıkışlar arasında gecikme olabilir."
        } catch { stopGroup(); message = error.localizedDescription }
    }

    @discardableResult func stopGroup() -> Bool {
        guard let id = aggregateID else { return true }
        let current = AudioControl.defaultOutput()
        if current == id {
            let available = AudioControl.outputs().filter { $0.id != id }
            guard let fallback = available.first(where: { $0.uid == originalUID }) ?? available.first(where: { !$0.isAggregate }) else { message = "Dönülecek ses çıkışı bulunamadı; grup korundu."; return false }
            do { try AudioControl.setDefault(fallback.id) } catch { message = error.localizedDescription; return false }
        }
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == noErr else { message = "Grup silinemedi: \(status)"; return false }
        aggregateID = nil; groupRunning = false
        defaults.removeObject(forKey: "ownedAggregate"); defaults.removeObject(forKey: "previousOutput")
        pollAudio()
        return true
    }

    private func recoverRouting() {
        if let levels = defaults.dictionary(forKey: "unisonNormalizedVolumes") as? [String: Double] {
            for (uid, level) in levels {
                if let output = outputs.first(where: { $0.uid == uid }), let current = AudioControl.volume(output.id), abs(current - 1) < 0.001 {
                    try? AudioControl.setVolume(output.id, value: level)
                }
            }
            defaults.removeObject(forKey: "unisonNormalizedVolumes")
        }
        if let mutes = defaults.dictionary(forKey: "unisonNormalizedMutes") as? [String: Bool] {
            for (uid, muted) in mutes where muted {
                if let output = outputs.first(where: { $0.uid == uid }), AudioControl.muted(output.id) == false {
                    try? AudioControl.setMute(output.id, muted: true)
                }
            }
            defaults.removeObject(forKey: "unisonNormalizedMutes")
        }
        if AudioControl.string(defaultID, kAudioDevicePropertyDeviceUID) == "org.unison.output" {
            let previous = defaults.string(forKey: "unisonNamedPreviousOutput")
            if let fallback = outputs.first(where: { $0.uid == previous }) ?? outputs.first(where: { !$0.isAggregate }) {
                try? AudioControl.setDefault(fallback.id)
                pollAudio()
            }
        }
        guard let owned = defaults.string(forKey: "ownedAggregate"), let stale = outputs.first(where: { $0.uid == owned }) else { return }
        if defaultID == stale.id {
            guard let fallback = outputs.first(where: { $0.uid == defaults.string(forKey: "previousOutput") }) ?? outputs.first(where: { !$0.isAggregate }) else { return }
            do { try AudioControl.setDefault(fallback.id) } catch { message = error.localizedDescription; return }
        }
        if AudioHardwareDestroyAggregateDevice(stale.id) == noErr { defaults.removeObject(forKey: "ownedAggregate"); defaults.removeObject(forKey: "previousOutput") }
        pollAudio()
    }

    var usesNativeVolumeKeys: Bool {
        let current = AudioControl.defaultOutput()
        if softwareAudioRunning || audioStarting { return systemVolume.deviceID != 0 && systemVolume.deviceID == current }
        return selected.count <= 1 && outputs.contains { $0.id == current && $0.volume != nil && (selected.isEmpty || selected.contains($0.uid)) }
    }

    private func syncNativeVolume(value: Double, muted: Bool?) {
        if let muted { master = value; masterMuted = muted }
        // Devices without a mute control use zero volume for mute. Preserve the
        // previous level until a native volume increase or an explicit unmute.
        else if !masterMuted || value > 0 { master = value; masterMuted = false }
    }

    func handleVolumeKey(_ key: Int) -> Bool {
        guard hasMasterTargets else { return false }
        if !softwareAudioRunning, !audioStarting, selected.count <= 1,
           let current = outputs.first(where: { $0.id == AudioControl.defaultOutput() && (selected.isEmpty || selected.contains($0.uid)) }),
           let value = AudioControl.volume(current.id) {
            syncNativeVolume(value: value, muted: AudioControl.muted(current.id))
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
        var text = "accessibility_trusted=\(AXIsProcessTrusted())\nevent_control_allowed=\(CGPreflightPostEventAccess())\nvolume_event_tap_active=\(keysEnabled)\nmaster_targets_available=\(hasMasterTargets)\nsystem_volume_linked=\(systemVolume.deviceID != 0)\nsystem_output_name=\(AudioControl.string(AudioControl.defaultOutput(), kAudioObjectPropertyName))\nnative_volume_keys=\(usesNativeVolumeKeys)\n"
        if let monitor = monitors.first(where: { $0.builtIn }), let value = monitor.brightness {
            text += "built_in_brightness=\(value)\nmaster_brightness=\(masterBrightness)\n"
        }
        try? text.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
    }

    func enableKeys(prompt: Bool = true) {
        guard !keysEnabled else { return }
        // The event tap is the actual capability check. Do not block it using
        // a separate permission preflight that can describe a different state.
        let keys = MediaKeys(nativeVolumeAvailable: { [weak self] in self?.usesNativeVolumeKeys ?? false }) { [weak self] key in self?.handleVolumeKey(key) ?? false }
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

    func startSoftwareAudio() {
        guard !audioStarting, !softwareAudioRunning else { return }
        if groupRunning && !stopGroup() { return }
        var targets = outputs.filter { selected.contains($0.uid) && !$0.isAggregate }
        if targets.isEmpty { targets = outputs.filter { $0.id == defaultID && !$0.isAggregate } }
        if targets.isEmpty { targets = Array(outputs.filter { !$0.isAggregate }.prefix(1)) }
        guard !targets.isEmpty else { message = "Fiziksel ses çıkışı bulunamadı."; return }
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
                        updateSoftwareGains(); pollAudio()
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
                            updateSoftwareGains(); pollAudio()
                        }
                        updateSoftwareGains()
                        message = "Yazılımsal ses etkin. HDMI sesi sürgülerden kontrol edilebilir."
                        audioTask = nil
                        break
                    }
                }
            } catch {
                guard let self, audioGeneration == generation else { return }
                stopSoftwareAudio()
                if !(error is CancellationError) { message = error.localizedDescription }
            }
        }
    }
    private func updateSoftwareGains() {
        guard softwareAudioRunning else { softwareAudio.gain(0); return }
        if systemVolume.deviceID == 0 {
            softwareAudio.gain(masterMuted ? 0 : master)
            for uid in softwareAudio.outputUIDs { softwareAudio.deviceGain(uid, value: deviceMuted.contains(uid) ? 0 : (deviceGains[uid] ?? 1) * (calibrations[uid] ?? 1)) }
        } else {
            softwareAudio.gain(masterMuted ? 0 : 1)
            for uid in softwareAudio.outputUIDs {
                softwareAudio.deviceGain(uid, value: LinkedVolumeGain.device(master: master, relative: deviceMuted.contains(uid) ? 0 : deviceGains[uid] ?? 1, calibration: calibrations[uid] ?? 1, isSystemDevice: uid == systemVolume.uid, muted: masterMuted, systemAmplitude: systemVolume.amplitude))
            }
        }
    }
    func stopSoftwareAudio() {
        audioGeneration += 1
        audioTask?.cancel(); audioTask = nil
        audioStarting = false
        systemVolume.stop(); softwareAudio.stop()
        softwareAudioRunning = false
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
    }
    func applyBrightness(_ value: Double) {
        masterBrightness = value.clamped
        for monitor in monitors where selectedDisplays.contains(monitor.id) { setBrightness(monitor, value: value) }
    }

    private func exportPreview(_ path: String) {
        // Render our own SwiftUI view as an artifact, without taking a desktop screenshot.
        let view = NSHostingView(rootView: ControlPanel(model: self))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)); print("Arayüz önizlemesi: \(path)") }
        }
        NSApp.terminate(nil)
    }
    private func audioSmoke() async {
        let previous = AudioControl.defaultOutput()
        let savedSelection = defaults.stringArray(forKey: "selectedOutputs")
        let savedMaster = defaults.object(forKey: "master")
        let priorMaster = master
        let priorMuted = masterMuted
        let physical = outputs.filter { !$0.isAggregate && ($0.name == "VG249Q3A" || $0.name.localizedCaseInsensitiveContains("MacBook")) }
        var report: [String] = ["accessibility_trusted=\(AXIsProcessTrusted())"]
        let speaker = physical.first { $0.volume != nil }
        let originalVolume = speaker.flatMap { AudioControl.volume($0.id) }
        let originalMute = speaker.flatMap { AudioControl.muted($0.id) }
        var sound: Process?
        do {
            guard physical.count >= 2 else { throw ControlError.message("İki fiziksel çıkış gerekli.") }
            report.append("physical_outputs=\(physical.map(\.name))")
            if let speaker, let originalVolume {
                // Exercise the same native path used by the MacBook row.
                routeTo(speaker)
                setOutputVolume(speaker, value: max(0.1, originalVolume * 0.8))
                let observed = AudioControl.volume(speaker.id) ?? -1
                let expected = max(0.1, originalVolume * 0.8)
                guard abs(observed - expected) < 0.01, AudioControl.defaultOutput() == speaker.id else { throw ControlError.message("MacBook yönlendirme/ses geri okuması başarısız.") }
                report.append("macbook_native_volume_and_route=PASS")
                master = 0.35; masterMuted = false; applyMaster()
                masterMuted = true; applyMaster(); poll()
                guard masterMuted, abs(master - 0.35) < 0.01, AudioControl.muted(speaker.id) == true else {
                    throw ControlError.message("Ortak sessize alma, kayıtlı ses seviyesini korumadı.")
                }
                master = 0.4; masterMuted = false; applyMaster()
                guard AudioControl.muted(speaker.id) == false, abs((AudioControl.volume(speaker.id) ?? -1) - 0.4) < 0.01 else {
                    throw ControlError.message("Ortak ses sürgüsü donanım sessizliğini kaldırmadı.")
                }
                report.append("native_master_mute_poll_and_unmute=PASS")

            }
            if CommandLine.arguments.contains("--keep-route") {
                try AudioControl.setDefault(previous)
                let deadline = Date().addingTimeInterval(2)
                while AudioControl.defaultOutput() != previous && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            if CommandLine.arguments.contains("--selection-smoke"), let speaker {
                routeTo(speaker)
                let routeDeadline = Date().addingTimeInterval(2)
                while AudioControl.defaultOutput() != speaker.id && Date() < routeDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                guard AudioControl.defaultOutput() == speaker.id else { throw ControlError.message("Ses testi için yerleşik yönlendirme tamamlanmadı.") }
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
                guard abs((AudioControl.volume(speaker.id) ?? -1) - master) < 0.01 else { throw ControlError.message("Ses beklenirken sistem seviyesi güncellenmedi.") }
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
            let deadline = Date().addingTimeInterval(2)
            while softwareAudio.signalBlocks == 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            guard softwareAudio.signalBlocks > 0 else {
                let log = source.isRunning ? "çalışıyor" : String(data: sourceLog.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ControlError.message("Ses kaynağı alınamadı: callback=\(softwareAudio.callbacks), giriş=\(softwareAudio.inputLayout), motor=\(softwareAudio.isRunning), bekleniyor=\(audioStarting), varsayılan=\(AudioControl.defaultOutput()), denetleyici=\(systemVolume.deviceID), durum=\(message), kaynak=\(source.isRunning), kayıt=\(log).")
            }
            report.append("before_activation_layout=\(softwareAudio.outputLayout)")
            if CommandLine.arguments.contains("--selection-smoke") {
                while audioStarting && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                guard softwareAudioRunning else { throw ControlError.message("Seçimden başlatılan motor etkinleşmedi.") }
                report.append("selection_starts_multi_output=PASS")
            } else { try softwareAudio.activate(master: 0.5) }
            try? await Task.sleep(for: .milliseconds(400))
            report.append("input_signals_after_activation=\(softwareAudio.signalBlocks)")
            let both = softwareAudio.deliveredBlocks
            report.append("output_layout=\(softwareAudio.outputLayout >> 16)buffers/\(softwareAudio.outputLayout & 0xffff)channels")
            report.append("output_signal_blocks=\(both)")
            guard both.count == physical.count, both.allSatisfy({ $0 > 0 }) else {
                throw ControlError.message("Çıkışlara ses yazılmadı: callback=\(softwareAudio.callbacks), motor=\(softwareAudio.isRunning), varsayılan=\(AudioControl.defaultOutput()), denetleyici=\(systemVolume.deviceID), ortak ses=\(master), sessiz=\(masterMuted), durum=\(message), kaynak=\(source.isRunning).")
            }
            report.append("both_outputs=PASS")
            if softwareAudioRunning, let speaker {
                let systemControlID = systemVolume.deviceID
                let nativeBefore = AudioControl.volume(systemControlID)
                guard systemControlID == speaker.id || systemVolume.uid == "org.unison.output" else { throw ControlError.message("Sistem ses denetimi bağlanmadı.") }
                let masterBefore = master
                busy = true
                let downHandled = handleVolumeKey(1)
                let lowered = master
                let systemLowered = AudioControl.volume(systemControlID) ?? -1
                let upHandled = handleVolumeKey(0)
                busy = false
                guard downHandled, upHandled, abs(lowered - (masterBefore - 0.0625)) < 0.001,
                      abs(master - masterBefore) < 0.001, abs(systemLowered - lowered) < 0.01, abs((AudioControl.volume(systemControlID) ?? -1) - (nativeBefore ?? -2)) < 0.01 else {
                    throw ControlError.message("Ortak ses tuşu denetimi başarısız.")
                }
                guard handleVolumeKey(7) else { throw ControlError.message("Sessiz tuşu işlenmedi.") }
                try? await Task.sleep(for: .milliseconds(100))
                let keyMuteBefore = softwareAudio.deliveredBlocks
                try? await Task.sleep(for: .milliseconds(150))
                guard softwareAudio.deliveredBlocks == keyMuteBefore else { throw ControlError.message("Ses tuşu tüm çıkışları susturmadı.") }
                _ = handleVolumeKey(7)
                report.append("volume_keys_common_gain_and_mute=PASS")
                try AudioControl.setVolume(systemControlID, value: 0.375)
                try? await Task.sleep(for: .milliseconds(100))
                guard abs(master - 0.375) < 0.01 else { throw ControlError.message("Sistem sürgüsü ortak sese geri yansımadı.") }
                report.append("control_center_volume_bidirectional=PASS")
                report.append("system_output_name=\(AudioControl.string(AudioControl.defaultOutput(), kAudioObjectPropertyName))")
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
            // Complete forwarding checks before exercising Bluetooth route
            // changes; a user route change intentionally stops forwarding.
            if let speaker {
                if source.isRunning { source.terminate() }
                stopSoftwareAudio()
                routeTo(speaker)
                let routeDeadline = Date().addingTimeInterval(2)
                while AudioControl.defaultOutput() != speaker.id && Date() < routeDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                pollAudio()
                if let other = outputs.first(where: { $0.id == previous && !$0.isAggregate && $0.volume != nil && $0.id != speaker.id }) {
                    try AudioControl.setDefault(other.id)
                    let switchDeadline = Date().addingTimeInterval(2)
                    while AudioControl.defaultOutput() != other.id && Date() < switchDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                    poll()
                    guard selected == [other.uid], usesNativeVolumeKeys, abs(master - (AudioControl.volume(other.id) ?? -1)) < 0.01 else {
                        throw ControlError.message("Sistem çıkışı değişimi: seçim=\(selected), varsayılan=\(defaultID), gerçek=\(AudioControl.defaultOutput()), beklenen=\(other.id), ortak ses=\(master), gerçek ses=\(AudioControl.volume(other.id) ?? -1), yerel tuşlar=\(usesNativeVolumeKeys).")
                    }
                    report.append("native_output_switch_follows_system=PASS")
                }
                try AudioControl.setVolume(speaker.id, value: 0.4)
                if AudioControl.outputs(includeController: true).contains(where: { $0.uid == "org.unison.output" }) {
                    try AudioControl.setMute(speaker.id, muted: true)
                    let bridgePrevious = AudioControl.defaultOutput()
                    do {
                        let bridge = SystemVolumeBridge()
                        defer { bridge.stop() }
                        try bridge.start(outputs: physical, value: 0.4, muted: false, preferNamedOutput: true, renderedUIDs: [speaker.uid]) { _, _ in }
                        guard AudioControl.muted(speaker.id) == false, abs((AudioControl.volume(speaker.id) ?? -1) - 1) < 0.01 else {
                            throw ControlError.message("Yazılımsal çıkışın donanım sessizliği kaldırılmadı.")
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    guard AudioControl.muted(speaker.id) == true, abs((AudioControl.volume(speaker.id) ?? -1) - 0.4) < 0.01,
                          AudioControl.defaultOutput() == bridgePrevious else {
                        throw ControlError.message("Yazılımsal çıkış geri yüklemesi: ses=\(AudioControl.volume(speaker.id) ?? -1), sessiz=\(AudioControl.muted(speaker.id).map(String.init) ?? "yok"), çıkış=\(AudioControl.defaultOutput()), beklenen=\(bridgePrevious).")
                    }
                    try AudioControl.setMute(speaker.id, muted: false)
                    report.append("normalized_hardware_mute_and_restore=PASS")
                }
            }
        } catch { report.append("ERROR=\(error.localizedDescription)") }
        if let sound, sound.isRunning { sound.terminate() }
        stopSoftwareAudio()
        if let speaker, let originalVolume { try? AudioControl.setVolume(speaker.id, value: originalVolume) }
        if let speaker, let originalMute { try? AudioControl.setMute(speaker.id, muted: originalMute) }
        try? AudioControl.setDefault(previous)
        let restoreDeadline = Date().addingTimeInterval(2)
        while AudioControl.defaultOutput() != previous && Date() < restoreDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        master = priorMaster; masterMuted = priorMuted
        if let savedSelection { defaults.set(savedSelection, forKey: "selectedOutputs") } else { defaults.removeObject(forKey: "selectedOutputs") }
        if let savedMaster { defaults.set(savedMaster, forKey: "master") } else { defaults.removeObject(forKey: "master") }
        report.append("previous_route_restored=\(AudioControl.defaultOutput() == previous)")
        if AudioControl.defaultOutput() != previous { report.append("ERROR=Önceki sistem çıkışı geri yüklenemedi.") }
        let text = report.joined(separator: "\n") + "\n"
        print(text)
        if let i = CommandLine.arguments.firstIndex(of: "--smoke-report"), CommandLine.arguments.count > i + 1 {
            try? text.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}

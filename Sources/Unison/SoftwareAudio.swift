import CoreAudio
import Foundation
import RealtimeAudio

@available(macOS 14.4, *)
@MainActor
final class SoftwareAudio {
    // A suspended startup retains only its own resources. Stopping/restarting
    // can never make an old task destroy the new task's tap or DSP state.
    private final class Session {
        var tap: AudioObjectID = 0
        var aggregate: AudioDeviceID = 0
        var callback: AudioDeviceIOProcID?
        var dsp: OpaquePointer?
        var description: CATapDescription?
        var outputUIDs: [String] = []

        func stop() {
            if let callback { _ = AudioDeviceStop(aggregate, callback); _ = AudioDeviceDestroyIOProcID(aggregate, callback) }
            callback = nil
            if aggregate != 0 { _ = AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
            if tap != 0 { _ = AudioHardwareDestroyProcessTap(tap); tap = 0 }
            if let dsp { unison_dsp_destroy(dsp) }; dsp = nil; outputUIDs = []; description = nil
        }
        deinit { stop() }
    }
    private var session: Session?
    private var dsp: OpaquePointer? { session?.dsp }
    var outputUIDs: [String] { session?.outputUIDs ?? [] }
    var isRunning: Bool { session?.callback != nil }
    var callbacks: UInt32 { dsp.map { unison_dsp_callback_count($0) } ?? 0 }
    var signalBlocks: UInt32 { dsp.map { unison_dsp_signal_count($0) } ?? 0 }
    var inputLayout: UInt32 { dsp.map { unison_dsp_input_layout($0) } ?? 0 }
    var outputLayout: UInt32 { dsp.map { unison_dsp_output_layout($0) } ?? 0 }
    var deliveredBlocks: [UInt32] { outputUIDs.indices.map { index in dsp.map { unison_dsp_device_signal_count($0, UInt32(index)) } ?? 0 } }
    var inputPeak: Double { dsp.map { Double(unison_dsp_input_peak($0)) } ?? 0 }
    var outputPeaks: [Double] { outputUIDs.indices.map { index in dsp.map { Double(unison_dsp_device_peak($0, UInt32(index))) } ?? 0 } }

    func start(outputs: [Output], calibration: [String: Double]) async throws {
        try Task.checkCancellation()
        stop()
        guard !outputs.isEmpty, outputs.count <= 16 else { throw ControlError.message("1–16 fiziksel çıkış seçin.") }
        let session = Session()
        session.outputUIDs = outputs.map(\.uid)
        self.session = session
        do {
            // Tap audio destined for the current route; the private aggregate forwards it.
            var processAddress = AudioControl.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid(), processID: AudioObjectID = 0, processSize: UInt32 = 4
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, UInt32(MemoryLayout.size(ofValue: pid)), &pid, &processSize, &processID)
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: processID == 0 ? [] : [processID])
            if processID == 0 {
                if #available(macOS 26.0, *) { desc.bundleIDs = [Bundle.main.bundleIdentifier ?? "org.unison.mac"] }
                else { throw ControlError.message("Uygulamanın kendi sesi güvenle hariç tutulamadı.") }
            }
            desc.name = "Unison Yerel Ses"
            desc.isPrivate = true
            // Keep original audio audible until an authorized, non-silent tap is proven.
            desc.muteBehavior = .unmuted
            session.description = desc
            try AudioControl.check(AudioHardwareCreateProcessTap(desc, &session.tap))
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var a = AudioControl.address(kAudioTapPropertyFormat)
            try AudioControl.check(AudioObjectGetPropertyData(session.tap, &a, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2 else { throw ControlError.message("Ses yakalama biçimi desteklenmiyor; normal ses korundu.") }
            let subdevices = outputs.enumerated().map { index, output in [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1] as [String: Any] }
            let tapUID = AudioControl.string(session.tap, kAudioTapPropertyUID)
            let description: [String: Any] = [kAudioAggregateDeviceNameKey: "Unison Ses İşleme", kAudioAggregateDeviceUIDKey: "org.unison.processing.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: 0, kAudioAggregateDeviceMainSubDeviceKey: outputs[0].uid, kAudioAggregateDeviceSubDeviceListKey: subdevices, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]], kAudioAggregateDeviceTapAutoStartKey: true]
            try AudioControl.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &session.aggregate))
            // HAL publishes the new aggregate before all sub-device streams are
            // attached. Registering an IOProc too early can freeze a partial layout.
            let expectedChannels = try outputs.reduce(UInt32(0)) { total, output in total + (try streamFormats(output.id).reduce(UInt32(0)) { $0 + $1.mChannelsPerFrame }) }
            _ = try await AudioReadiness.wait {
                guard self.session === session else { throw CancellationError() }
                return self.outputChannelCount(session.aggregate) >= expectedChannels
            }
            try Task.checkCancellation()
            guard self.session === session else { throw CancellationError() }
            let actualChannels = outputChannelCount(session.aggregate)
            guard actualChannels == expectedChannels else { throw ControlError.message("Ses grubunun tüm çıkış kanalları hazır değil: \(actualChannels) / \(expectedChannels).") }
            var rateAddress = AudioControl.address(kAudioDevicePropertyNominalSampleRate), rate: Float64 = 0, rateSize: UInt32 = 8
            try AudioControl.check(AudioObjectGetPropertyData(session.aggregate, &rateAddress, 0, nil, &rateSize, &rate))
            guard abs(rate - format.mSampleRate) < 1 else { throw ControlError.message("Ses örnekleme hızları eşleşmiyor; normal çıkış korundu.") }
            guard let state = unison_dsp_create() else { throw ControlError.message("Ses belleği ayrılamadı.") }
            session.dsp = state
            for (index, output) in outputs.enumerated() {
                let streams = try streamFormats(output.id)
                guard !streams.isEmpty, streams.allSatisfy({ $0.mFormatID == kAudioFormatLinearPCM && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mBitsPerChannel == 32 && abs($0.mSampleRate - rate) < 1 }) else { throw ControlError.message("\(output.name) ses biçimi bu sürümde desteklenmiyor.") }
                let channels = streams.reduce(UInt32(0)) { $0 + $1.mChannelsPerFrame }
                unison_dsp_set_device(state, UInt32(index), channels, Float(calibration[output.uid] ?? 1))
            }
            unison_dsp_set_gain(state, 0)
            try AudioControl.check(AudioDeviceCreateIOProcID(session.aggregate, unison_audio_callback, UnsafeMutableRawPointer(state), &session.callback))
            try AudioControl.check(AudioDeviceStart(session.aggregate, session.callback))
        } catch {
            if self.session === session { self.session = nil }
            session.stop()
            throw error
        }
    }
    private func streamFormats(_ device: AudioDeviceID) throws -> [AudioStreamBasicDescription] {
        var a = AudioControl.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), size: UInt32 = 0
        try AudioControl.check(AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size))
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
        try AudioControl.check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, &streams))
        return try streams.map { stream in
            var a = AudioControl.address(kAudioStreamPropertyVirtualFormat), format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioControl.check(AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &format))
            return format
        }
    }
    private func outputChannelCount(_ aggregate: AudioDeviceID) -> UInt32 {
        var a = AudioControl.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(aggregate, &a, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }
    func gain(_ value: Double) { if let dsp { unison_dsp_set_gain(dsp, Float(value.clamped)) } }
    // Diagnostic runs can isolate their tone from other apps playing audio.
    func isolateCapture(processID: AudioObjectID) throws {
        guard processID != 0, let session, let description = session.description else { throw ControlError.message("Test ses süreci bulunamadı.") }
        description.processes = [processID]
        description.isExclusive = false
        var a = AudioControl.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description)
        try AudioControl.check(AudioObjectSetPropertyData(session.tap, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference))
    }
    func activate(master: Double) throws {
        guard signalBlocks > 0, let session, let description = session.description else { throw ControlError.message("Ses akışı henüz doğrulanmadı.") }
        description.muteBehavior = .mutedWhenTapped
        var a = AudioControl.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description)
        try AudioControl.check(AudioObjectSetPropertyData(session.tap, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference))
        gain(master)
    }
    func deviceGain(_ uid: String, value: Double) { if let dsp, let index = outputUIDs.firstIndex(of: uid) { unison_dsp_set_device(dsp, UInt32(index), 0, Float(value.clamped)) } }
    func stop() {
        session?.stop()
        session = nil
    }
}

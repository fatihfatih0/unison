import SwiftUI
import AppKit

@main
struct UnisonApp: App {
    @StateObject private var model = ControlModel()
    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(nsImage: Branding.menuIcon)
                .accessibilityLabel("Unison · Ses ve parlaklık")
        }.menuBarExtraStyle(.window)
    }
}

private enum Palette {
    static let blue = Color(red: 0.19, green: 0.56, blue: 1)
    static let muted = Color.white.opacity(0.36)
    static let green = Color(red: 0.24, green: 0.95, blue: 0.46)
}

struct ControlPanel: View {
    @ObservedObject var model: ControlModel
    @State private var settings = false
    @State private var expandedOutput: String?
    @State private var expandedDisplay: String?
    @State private var outputsExpanded = true
    @State private var displaysExpanded = true
    @State private var night = false
    @State private var beforeNight = 1.0

    private var visibleOutputs: [Output] { model.outputs.filter { !$0.uid.hasPrefix("org.unison.") } }
    private var activeOutputs: [Output] { visibleOutputs.filter { model.selected.contains($0.uid) || (model.selected.isEmpty && $0.id == model.defaultID) } }

    var body: some View {
        VStack(spacing: 8) {
            GlassCard {
                VStack(spacing: 15) {
                    HStack(spacing: 17) {
                        Image(nsImage: Branding.applicationIcon).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                        Text("UNISON").font(.system(size: 11, weight: .bold)).tracking(3.2).foregroundStyle(Palette.muted)
                        Spacer()
                        Button {
                            if model.softwareAudioRunning || model.audioStarting { model.stopSoftwareAudio() } else { model.startSoftwareAudio() }
                        } label: { Image(systemName: "square.stack.3d.up").foregroundStyle(model.softwareAudioRunning ? Palette.blue : Palette.muted) }
                        .help(model.softwareAudioRunning ? "Yazılımsal sesi durdur" : "HDMI için yazılımsal sesi başlat")
                        Button {
                            night.toggle()
                            if night { beforeNight = model.masterBrightness; model.applyBrightness(0.3) }
                            else { model.applyBrightness(beforeNight) }
                        } label: { Image(systemName: night ? "moon.fill" : "moon").foregroundStyle(night ? Palette.blue : Palette.muted) }
                        .disabled(model.selectedDisplays.isEmpty || model.busy).help("Gece parlaklığı")
                        Button { settings.toggle() } label: { Image(systemName: "gearshape").foregroundStyle(Palette.muted) }
                            .popover(isPresented: $settings, arrowEdge: .trailing) { settingsPanel }
                    }.font(.system(size: 12)).padding(.horizontal, 2)

                    HStack(spacing: 9) {
                        Circle().fill(model.groupRunning || model.softwareAudioRunning ? Palette.green : Color.white.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .shadow(color: model.groupRunning || model.softwareAudioRunning ? Palette.green.opacity(0.7) : .clear, radius: 6)
                        Text(model.audioStarting ? "Ses bekleniyor" : model.softwareAudioRunning ? "Ses işleniyor" : model.groupRunning ? "Çoklu çıkış" : "Hazır")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        ForEach(Array(activeOutputs.prefix(3))) { output in
                            Button { model.routeTo(output) } label: { DeviceBadge(symbol: icon(output), size: 27, active: true) }
                                .help("\(output.name) çıkışına geç")
                        }
                        if activeOutputs.isEmpty {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.muted)
                        }
                    }.padding(.horizontal, 13).frame(height: 45)
                        .background(RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(red: 0.23, green: 0.31, blue: 0.37), Color(red: 0.07, green: 0.14, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing)))

                    HStack(spacing: 11) {
                        Button {
                            model.masterMuted.toggle(); model.applyMaster()
                        } label: { RoundControl(symbol: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                        .disabled(!model.hasMasterTargets).help("Ortak sesi aç / kapat")
                        BlueSlider(value: model.masterMuted ? 0 : model.master, enabled: model.hasMasterTargets, label: "Ortak ses") {
                            model.master = $0; model.masterMuted = false; model.applyMaster()
                        }
                    }
                    HStack(spacing: 11) {
                        RoundControl(symbol: "sun.max.fill")
                        BlueSlider(value: model.masterBrightness, enabled: !model.selectedDisplays.isEmpty, label: "Ortak parlaklık") { model.applyBrightness($0) }
                    }
                }.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 13)
            }

            GlassCard {
                VStack(spacing: 0) {
                    sectionHeader("ÇIKIŞLAR", count: "\(activeOutputs.count) / \(visibleOutputs.count) seçili", expanded: $outputsExpanded)
                    if outputsExpanded {
                        VStack(spacing: 13) {
                            ForEach(visibleOutputs) { output in outputRow(output) }
                            if visibleOutputs.isEmpty { emptyLabel("Ses çıkışı bulunamadı") }
                        }.padding(.horizontal, 6).padding(.bottom, 10)
                    }
                }
            }

            GlassCard {
                VStack(spacing: 0) {
                    sectionHeader("EKRANLAR", count: "\(model.monitors.filter { model.selectedDisplays.contains($0.id) }.count) / \(model.monitors.count) seçili", expanded: $displaysExpanded)
                    if displaysExpanded {
                        VStack(spacing: 13) {
                            ForEach(model.monitors) { monitor in displayRow(monitor) }
                            if model.monitors.isEmpty { emptyLabel(model.busy ? "Ekranlar aranıyor…" : "Ekran bulunamadı") }
                        }.padding(.horizontal, 6).padding(.bottom, 14)
                    }
                }
            }
            if !model.message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").padding(.top, 1)
                    Text(model.message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.message = "" } label: { Image(systemName: "xmark") }.help("Bildirimi kapat")
                }.font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.6)).padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
            }
        }
        .buttonStyle(.plain)
        .padding(6)
        .frame(width: 306)
        .background(Color(red: 0.055, green: 0.06, blue: 0.064))
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ title: String, count: String, expanded: Binding<Bool>) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.wrappedValue.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                Text(title).font(.system(size: 10, weight: .bold)).tracking(1.6)
                Spacer()
                Text(count).font(.system(size: 10, weight: .medium))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 14).frame(height: 31)
        }
    }

    private func outputRow(_ output: Output) -> some View {
        let active = model.selected.contains(output.uid) || (model.selected.isEmpty && output.id == model.defaultID)
        let value = model.outputValue(output)
        return VStack(spacing: 5) {
            HStack(spacing: 10) {
                Button { model.toggleOutput(output, enabled: !active) } label: { DeviceBadge(symbol: icon(output), active: active) }
                    .disabled(output.isAggregate)
                    .help(active ? "Gruptan çıkar" : "Ses grubuna ekle")
                Button { expandedOutput = expandedOutput == output.uid ? nil : output.uid } label: {
                    HStack {
                        Text(output.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if output.isAggregate { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Palette.muted) }
                        Image(systemName: expandedOutput == output.uid ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    }.contentShape(Rectangle())
                }
            }.padding(.horizontal, 10).frame(height: 44)
                .background(rowBackground(active: active))
            BlueSlider(value: value ?? 0, enabled: value != nil, label: "\(output.name) ses seviyesi") { model.setOutputVolume(output, value: $0) }
                .padding(.leading, 50).padding(.trailing, 13)
            if expandedOutput == output.uid {
                VStack(alignment: .leading, spacing: 10) {
                    if value == nil && !output.isAggregate {
                        Text("HDMI sesi için yazılımsal ses kontrolünü etkinleştirin.").font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("Yazılımsal sesi etkinleştir") { model.startSoftwareAudio() }.disabled(model.busy)
                    }
                    HStack {
                        Button("Bu çıkışı kullan") { model.routeTo(output) }
                        Spacer()
                        if model.outputMuted(output) != nil {
                            Button(model.outputMuted(output) == true ? "Sesi aç" : "Sessize al") { model.toggleMute(output) }
                        }
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.blue)
                    if !output.isAggregate && active {
                        Text("Ses dengeleme").font(.system(size: 10)).foregroundStyle(.secondary)
                        BlueSlider(value: model.calibrations[output.uid] ?? 1, label: "Ses dengeleme") { model.setCalibration(output, value: $0) }
                    }
                }.padding(.horizontal, 13).padding(.vertical, 7)
            }
        }
    }

    private func displayRow(_ monitor: Monitor) -> some View {
        let active = model.selectedDisplays.contains(monitor.id)
        let software = !monitor.builtIn && monitor.brightness == nil && !monitor.manual
        return VStack(spacing: 5) {
            HStack(spacing: 10) {
                Button { model.toggleDisplay(monitor.id) } label: { DeviceBadge(symbol: monitor.builtIn ? "laptopcomputer" : "display", active: active) }
                    .help(active ? "Parlaklık grubundan çıkar" : "Parlaklık grubuna ekle")
                Button { expandedDisplay = expandedDisplay == monitor.id ? nil : monitor.id } label: {
                    HStack {
                        Text(monitor.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if software { Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        Image(systemName: expandedDisplay == monitor.id ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    }.contentShape(Rectangle())
                }
            }.padding(.horizontal, 10).frame(height: 44).background(rowBackground(active: active))
            BlueSlider(value: model.brightnessValue(monitor), minimum: software ? 0.2 : 0, label: "\(monitor.name) parlaklık") { model.setBrightness(monitor, value: $0) }
                .padding(.leading, 50).padding(.trailing, 13)
            if expandedDisplay == monitor.id {
                VStack(alignment: .leading, spacing: 10) {
                    Text(monitor.builtIn ? "Yerleşik ekran · Donanım parlaklığı" : software ? "Yazılımsal karartma · Arka ışık değişmez" : "DDC · Donanım parlaklığı")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !monitor.builtIn {
                        Toggle("Elle DDC kontrolü", isOn: Binding(get: { monitor.manual }, set: { model.setManual(monitor.id, enabled: $0) })).toggleStyle(.checkbox)
                            .font(.system(size: 10))
                        if monitor.brightness == nil { Text("Ekran DDC değerini geri okumuyor. Elle gönderilen değer doğrulanamayabilir.").font(.system(size: 10)).foregroundStyle(.secondary) }
                        if monitor.volume != nil || monitor.manual {
                            Text("Monitör hoparlörü").font(.system(size: 10)).foregroundStyle(.secondary)
                            BlueSlider(value: monitor.volume ?? 0.5, enabled: !model.busy, label: "Monitör hoparlörü") { model.writeDisplay(monitor.id, feature: "volume", value: $0) }
                            Toggle("Ortak sese bağla", isOn: Binding(get: { model.linkedMonitors.contains(monitor.id) }, set: { model.linkMonitor(monitor.id, enabled: $0) })).toggleStyle(.checkbox).font(.system(size: 10))
                        }
                    }
                }.padding(.horizontal, 13).padding(.vertical, 7)
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Unison ayarları").font(.headline); Spacer(); Button { settings = false } label: { Image(systemName: "xmark") } }
            Text("SES").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.secondary)
            Button(model.softwareAudioRunning || model.audioStarting ? "Yazılımsal sesi durdur" : "Yazılımsal sesi başlat") { if model.softwareAudioRunning || model.audioStarting { model.stopSoftwareAudio() } else { model.startSoftwareAudio() } }
                .disabled(model.busy)
            Text("HDMI ve diğer çıkışların sesini yerel olarak işler. macOS ses yakalama izni gerekir. Ses kaydedilmez.").font(.caption).foregroundStyle(.secondary)
            Button(model.groupRunning ? "Donanım grubunu durdur" : "Seçili çıkışlarda birlikte çal") { if model.groupRunning { model.stopGroup() } else { model.startGroup() } }
                .disabled(!model.groupRunning && (model.selected.count < 2 || model.softwareAudioRunning))
            Button(model.keysEnabled ? "F11/F12 · Ortak ses etkin" : "F11/F12 · Erişilebilirlik izni ver") { model.enableKeys() }.disabled(model.keysEnabled)
            Divider()
            Toggle("Girişte başlat", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            Button("Ekranları ve çıkışları yenile") { model.pollAudio(); Task { await model.refreshDisplays() } }.disabled(model.busy)
            Divider()
            Button("Unison'dan çık") { model.stopSoftwareAudio(); if model.stopGroup() { NSApp.terminate(nil) } }
        }.font(.system(size: 12)).padding(18).frame(width: 280).preferredColorScheme(.dark)
    }
    private func icon(_ output: Output) -> String {
        if output.isAggregate { return "speaker.fill" }
        if output.name.localizedCaseInsensitiveContains("MacBook") { return "laptopcomputer" }
        if model.monitors.contains(where: { !$0.builtIn && $0.name == output.name }) { return "display" }
        return "speaker.wave.2.fill"
    }
    private func rowBackground(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: active ? [Color(red: 0.19, green: 0.27, blue: 0.32), Color(red: 0.06, green: 0.12, blue: 0.16)] : [Color(red: 0.09, green: 0.13, blue: 0.16), Color(red: 0.07, green: 0.10, blue: 0.13)], startPoint: .leading, endPoint: .trailing))
    }
    private func emptyLabel(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(15) }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [Color(red: 0.26, green: 0.27, blue: 0.27), Color(red: 0.13, green: 0.14, blue: 0.14), Color(red: 0.055, green: 0.065, blue: 0.066)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
    }
}

private struct DeviceBadge: View {
    let symbol: String
    var size: CGFloat = 30
    let active: Bool
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(active ? .white : .white.opacity(0.5))
            .frame(width: size, height: size)
            .background(Circle().fill(active ? Palette.blue : Color(red: 0.08, green: 0.27, blue: 0.5)))
    }
}

private struct RoundControl: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            .frame(width: 32, height: 32)
            .background(Circle().fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

struct BlueSlider: View {
    let value: Double
    var enabled = true
    var minimum: Double = 0
    let label: String
    let action: (Double) -> Void
    @State private var draft: Double?
    @State private var hovering = false
    var body: some View {
        GeometryReader { geometry in
            let fraction = (draft ?? value).clamped
            let radius: CGFloat = 7
            let travel = max(1, geometry.size.width - radius * 2)
            let position = radius + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(hovering && enabled ? 0.3 : 0.18)).frame(height: hovering && enabled ? 6 : 4)
                if enabled {
                    Capsule().fill(Palette.blue).frame(width: max(0, position), height: 4)
                        .shadow(color: Palette.blue.opacity(0.65), radius: 4)
                    Circle().fill(Color.white)
                        .overlay(Circle().stroke(Palette.blue, lineWidth: 2))
                        .frame(width: radius * 2, height: radius * 2)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .scaleEffect(draft != nil ? 1.2 : (hovering ? 1.15 : 1))
                        .shadow(color: Palette.blue.opacity(hovering ? 0.7 : 0), radius: 6)
                        .offset(x: position - radius)
                }
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        let next = max(minimum, ((gesture.location.x - radius) / travel).clamped)
                        draft = next
                        action(next)
                    }
                    .onEnded { _ in guard enabled else { return }; if let draft { action(draft) }; draft = nil })
        }.frame(height: 24)
        .background(SliderScrollInput(value: draft ?? value, minimum: minimum, enabled: enabled, action: action))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .opacity(enabled ? 1 : 0.45)
        .help(enabled ? "\(label): %\(Int(value * 100)) · Sürükleyin, mouse tekerleğini kullanın veya iki parmakla sağa/sola kaydırın" : "\(label): Kontrol için ses işlemeyi etkinleştirin")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(enabled ? "%\(Int(value * 100))" : "Kullanılamıyor")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            action(max(minimum, (value + (direction == .increment ? 0.05 : -0.05)).clamped))
        }
    }
}

/// Consume scrolling over a slider, preserving SwiftUI dragging and letting
/// the surrounding device list scroll when the pointer is outside a slider.
private struct SliderScrollInput: NSViewRepresentable {
    let value: Double
    let minimum: Double
    let enabled: Bool
    let action: (Double) -> Void

    func makeNSView(context: Context) -> ScrollRegion { ScrollRegion() }

    func updateNSView(_ view: ScrollRegion, context: Context) {
        view.value = value
        view.minimum = minimum
        view.enabled = enabled
        view.action = action
    }

    static func dismantleNSView(_ view: ScrollRegion, coordinator: ()) { view.stopObserving() }

    final class ScrollRegion: NSView {
        var value = 0.0
        var minimum = 0.0
        var enabled = true
        var action: ((Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                guard delta != 0 else { return event }
                // Rightward swipes and upward wheel movements increase the
                // value, independently of the Natural Scrolling preference.
                let direction = horizontal
                    ? (event.isDirectionInvertedFromDevice ? 1.0 : -1.0)
                    : (event.isDirectionInvertedFromDevice ? -1.0 : 1.0)
                let sensitivity = event.hasPreciseScrollingDeltas ? 900.0 : 100.0
                let next = max(self.minimum, min(1, self.value + direction * delta / sensitivity))
                if next != self.value {
                    self.value = next
                    self.action?(next)
                }
                return nil
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopObserving() }
    }
}

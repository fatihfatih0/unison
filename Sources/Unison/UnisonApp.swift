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

// Shared tokens keep the panel, controls and settings visually consistent.
private enum Palette {
    static let background = Color(red: 0.065, green: 0.078, blue: 0.106)
    static let surface = Color(red: 0.105, green: 0.125, blue: 0.164)
    static let raised = Color(red: 0.14, green: 0.165, blue: 0.21)
    static let text = Color(red: 0.95, green: 0.97, blue: 1)
    static let secondary = Color(red: 0.65, green: 0.71, blue: 0.80)
    static let blue = Color(red: 0.40, green: 0.68, blue: 1)
    static let amber = Color(red: 0.96, green: 0.75, blue: 0.41)
    static let green = Color(red: 0.43, green: 0.86, blue: 0.69)
    static let track = Color(red: 0.42, green: 0.48, blue: 0.57)
    static let border = Color.white.opacity(0.10)
}

private struct PreviewReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var unisonPreviewReduceMotion: Bool {
        get { self[PreviewReduceMotionKey.self] }
        set { self[PreviewReduceMotionKey.self] = newValue }
    }
}

struct ControlPanel: View {
    @ObservedObject var model: ControlModel
    @State private var settings = false
    @State private var expandedOutput: String?
    @State private var expandedDisplay: String?
    @State private var showingDisplays = false
    @State private var night = false
    @State private var beforeNight = 1.0

    init(model: ControlModel, showingDisplays: Bool = false, expandedDetails: Bool = false) {
        self.model = model
        _showingDisplays = State(initialValue: showingDisplays)
        _expandedOutput = State(initialValue: expandedDetails ? model.outputs.first(where: { !$0.uid.hasPrefix("org.unison.") })?.uid : nil)
        _expandedDisplay = State(initialValue: expandedDetails ? model.monitors.first?.id : nil)
    }

    private var visibleOutputs: [Output] { model.outputs.filter { !$0.uid.hasPrefix("org.unison.") } }
    private var activeOutputs: [Output] { visibleOutputs.filter { isActive($0) } }
    private var selectedDisplayCount: Int { model.monitors.filter { model.selectedDisplays.contains($0.id) }.count }
    private var engineActive: Bool { model.softwareAudioRunning || model.audioStarting }
    private var listHeight: CGFloat {
        let outputs = max(1, visibleOutputs.count) * 99 + (expandedOutput == nil ? 0 : 145)
        let displays = max(1, model.monitors.count) * 99 + (expandedDisplay == nil ? 0 : 185)
        let shortestScreen = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 900
        let available = shortestScreen - 480 - (model.message.isEmpty ? 0 : 76)
        return min(CGFloat(showingDisplays ? displays : outputs), max(100, min(340, available)))
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            sharedControls
            engineControl
            deviceTabs
            ScrollView {
                VStack(spacing: 8) {
                    if showingDisplays {
                        ForEach(model.monitors) { monitor in displayRow(monitor) }
                        if model.monitors.isEmpty { emptyLabel(model.busy ? "Ekranlar aranıyor…" : "Ekran bulunamadı", symbol: "display") }
                    } else {
                        ForEach(visibleOutputs) { output in outputRow(output) }
                        if visibleOutputs.isEmpty { emptyLabel("Ses çıkışı bulunamadı", symbol: "speaker.slash") }
                    }
                }.padding(.horizontal, 2).padding(.bottom, 4)
            }
            .scrollIndicators(.visible)
            .frame(height: listHeight)
            if !model.message.isEmpty {
                ScrollView { messageCard }.frame(maxHeight: 76)
            }
            HStack(spacing: 5) {
                Image(systemName: "hand.draw").accessibilityHidden(true)
                Text("Sürükle, kaydır veya ok tuşlarını kullan")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        .padding(14)
        .frame(width: 354)
        .foregroundStyle(Palette.text)
        .buttonStyle(PanelButtonStyle())
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Palette.surface, Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border))
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Branding.applicationIcon).resizable().frame(width: 34, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unison").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("Ses ve ekran, bir arada.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            Button {
                night.toggle()
                if night { beforeNight = model.masterBrightness; model.applyBrightness(0.3) }
                else { model.applyBrightness(beforeNight) }
            } label: { ToolbarIcon(symbol: night ? "moon.fill" : "moon", tint: night ? Palette.amber : Palette.secondary) }
                .disabled(model.selectedDisplays.isEmpty || model.busy)
                .accessibilityLabel("Gece parlaklığı")
                .accessibilityValue(night ? "Açık" : "Kapalı")
                .help("Gece parlaklığını aç / kapat")
            Button { settings.toggle() } label: { ToolbarIcon(symbol: "slider.horizontal.3", tint: Palette.secondary) }
                .accessibilityLabel("Unison ayarları")
                .help("Unison ayarları")
                .popover(isPresented: $settings, arrowEdge: .trailing) { settingsPanel }
        }.frame(minHeight: 42)
    }

    private var sharedControls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Ortak kontrol").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(activeOutputs.count) ses · \(selectedDisplayCount) ekran")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            }
            sharedSlider(title: "Ses", value: model.masterMuted ? 0 : model.master, tint: Palette.blue, enabled: model.hasMasterTargets) {
                Button { model.masterMuted.toggle(); model.applyMaster() } label: {
                    ControlIcon(symbol: model.masterMuted ? "speaker.slash" : "speaker.wave.2", tint: Palette.blue)
                }.disabled(!model.hasMasterTargets)
                    .accessibilityLabel(model.masterMuted ? "Ortak sesi aç" : "Ortak sesi sessize al")
                    .help("Ortak sesi aç / kapat")
            } action: {
                model.master = $0; model.masterMuted = false; model.applyMaster()
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            sharedSlider(title: "Parlaklık", value: model.masterBrightness, tint: Palette.amber, enabled: !model.selectedDisplays.isEmpty) {
                ControlIcon(symbol: "sun.max", tint: Palette.amber).accessibilityHidden(true)
            } action: { model.applyBrightness($0) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
    }

    private func sharedSlider<Icon: View>(title: String, value: Double, tint: Color, enabled: Bool, @ViewBuilder icon: () -> Icon, action: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            icon()
            VStack(spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Percentage(value: enabled ? value : nil, tint: tint, prominent: true)
                }
                BlueSlider(value: value, enabled: enabled, label: "Ortak \(title.lowercased())", tint: tint, action: action)
            }
        }
    }

    private var engineControl: some View {
        Button {
            if engineActive { model.stopSoftwareAudio() } else { model.startSoftwareAudio() }
        } label: {
            HStack(spacing: 8) {
                if model.audioStarting {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: engineActive ? "checkmark.circle.fill" : "waveform.path")
                        .foregroundStyle(engineActive ? Palette.green : Palette.blue).accessibilityHidden(true)
                }
                Text(model.audioStarting ? "Ses akışı bekleniyor" : model.softwareAudioRunning ? "HDMI ve çoklu ses etkin" : model.groupRunning ? "Çoklu çıkış etkin" : "HDMI ve çoklu ses")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(engineActive ? "Durdur" : "Etkinleştir").font(.system(size: 11, weight: .semibold)).foregroundStyle(engineActive ? Palette.secondary : Palette.blue)
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.blue.opacity(0.07)))
        .accessibilityLabel(engineActive ? "Yazılımsal sesi durdur" : "HDMI ve çoklu sesi etkinleştir")
        .help(engineActive ? "Ses işlemeyi durdur ve normal çıkışa dön" : "HDMI ve seçili hoparlörler için ses kontrolünü etkinleştir")
    }

    private var deviceTabs: some View {
        HStack(spacing: 4) {
            deviceTab("Ses çıkışları", symbol: "speaker.wave.2", count: "\(activeOutputs.count)/\(visibleOutputs.count)", displays: false)
            deviceTab("Ekranlar", symbol: "display", count: "\(selectedDisplayCount)/\(model.monitors.count)", displays: true)
        }.padding(4).background(RoundedRectangle(cornerRadius: 12).fill(Palette.background))
    }

    private func deviceTab(_ title: String, symbol: String, count: String, displays: Bool) -> some View {
        let selected = showingDisplays == displays
        return Button { showingDisplays = displays } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(count).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Palette.secondary)
            }.foregroundStyle(selected ? Palette.text : Palette.secondary)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Palette.raised : .clear))
        }.accessibilityLabel("\(title), \(count) seçili")
            .accessibilityValue(selected ? "Seçili sekme" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isActive(_ output: Output) -> Bool {
        model.selected.contains(output.uid) || (model.selected.isEmpty && output.id == model.defaultID)
    }

    private func outputRow(_ output: Output) -> some View {
        let active = isActive(output)
        let value = model.outputValue(output)
        return VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button { model.toggleOutput(output, enabled: !active) } label: {
                    DeviceBadge(symbol: icon(output), active: active, tint: Palette.blue)
                }.disabled(output.isAggregate)
                    .accessibilityLabel("\(output.name), \(active ? "ses grubundan çıkar" : "ses grubuna ekle")")
                    .accessibilityValue(active ? "Seçili" : "Seçili değil")
                    .help(active ? "Ses grubundan çıkar" : "Ses grubuna ekle")
                Button { expandedOutput = expandedOutput == output.uid ? nil : output.uid } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(output.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(output.isAggregate ? "macOS çoklu çıkış aygıtı" : active ? "Seçili · \(outputKind(output))" : outputKind(output))
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if output.isAggregate { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        Image(systemName: expandedOutput == output.uid ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                    }.contentShape(Rectangle())
                }.help(output.name).accessibilityLabel("\(output.name) ayrıntıları")
                    .accessibilityValue(expandedOutput == output.uid ? "Açık" : "Kapalı")
            }
            if let value {
                HStack(spacing: 10) {
                    BlueSlider(value: value, label: "\(output.name) ses seviyesi") { model.setOutputVolume(output, value: $0) }
                    Percentage(value: value, tint: Palette.secondary)
                }.padding(.leading, 48)
            } else if !output.isAggregate {
                Button {
                    if !active { model.toggleOutput(output, enabled: true) }
                    if !engineActive { model.startSoftwareAudio() }
                } label: {
                    Label("Ses kontrolünü etkinleştir", systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 22)
                }.disabled(model.audioStarting).padding(.leading, 48)
            } else {
                Text("Sistem tarafından yönetiliyor").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 48)
            }
            if expandedOutput == output.uid { outputDetails(output, value: value, active: active) }
        }
        .padding(12)
        .background(rowBackground(active: active, tint: Palette.blue))
    }

    private func outputDetails(_ output: Output, value: Double?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.border)
            Text(output.name).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Bu çıkışı kullan") { model.routeTo(output) }
                Spacer()
                if model.outputMuted(output) != nil {
                    Button(model.outputMuted(output) == true ? "Sesi aç" : "Sessize al") { model.toggleMute(output) }
                }
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.blue)
            if value == nil && !output.isAggregate {
                Text("HDMI sesi, Unison çalışırken kontrol edilir. Ses yakalama izni gerekir.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !output.isAggregate && active {
                HStack { Text("Ses dengeleme"); Spacer(); Percentage(value: model.calibrations[output.uid] ?? 1, tint: Palette.secondary) }
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                BlueSlider(value: model.calibrations[output.uid] ?? 1, label: "\(output.name) ses dengeleme") { model.setCalibration(output, value: $0) }
            }
        }.padding(.top, 3)
    }

    private func displayRow(_ monitor: Monitor) -> some View {
        let active = model.selectedDisplays.contains(monitor.id)
        let software = !monitor.builtIn && monitor.brightness == nil && !monitor.manual
        let value = model.brightnessValue(monitor)
        return VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button { model.toggleDisplay(monitor.id) } label: {
                    DeviceBadge(symbol: monitor.builtIn ? "laptopcomputer" : "display", active: active, tint: Palette.amber)
                }.accessibilityLabel("\(monitor.name), \(active ? "parlaklık grubundan çıkar" : "parlaklık grubuna ekle")")
                    .accessibilityValue(active ? "Seçili" : "Seçili değil")
                    .help(active ? "Parlaklık grubundan çıkar" : "Parlaklık grubuna ekle")
                Button { expandedDisplay = expandedDisplay == monitor.id ? nil : monitor.id } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text("\(active ? "Seçili · " : "")\(monitor.builtIn ? "Yerleşik ekran" : software ? "Yazılımsal karartma" : "Donanım parlaklığı")")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expandedDisplay == monitor.id ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                    }.contentShape(Rectangle())
                }.help(monitor.name).accessibilityLabel("\(monitor.name) ayrıntıları")
                    .accessibilityValue(expandedDisplay == monitor.id ? "Açık" : "Kapalı")
            }
            HStack(spacing: 10) {
                BlueSlider(value: value, minimum: software ? 0.2 : 0, label: "\(monitor.name) parlaklık", tint: Palette.amber) { model.setBrightness(monitor, value: $0) }
                Percentage(value: value, tint: Palette.secondary)
            }.padding(.leading, 48)
            if expandedDisplay == monitor.id { displayDetails(monitor, software: software) }
        }.padding(12).background(rowBackground(active: active, tint: Palette.amber))
    }

    private func displayDetails(_ monitor: Monitor, software: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.border)
            Text(monitor.name).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(monitor.builtIn ? "Mac'in donanım parlaklığı. F1/F2 değişiklikleri burada görünür." : software ? "Görüntüyü karartır; fiziksel arka ışık değişmez." : "DDC ile monitörün donanım parlaklığı ayarlanır.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if !monitor.builtIn {
                Toggle("Elle DDC kontrolü", isOn: Binding(get: { monitor.manual }, set: { model.setManual(monitor.id, enabled: $0) })).toggleStyle(.checkbox)
                if monitor.brightness == nil {
                    Text("Elle DDC değerleri monitörden doğrulanamayabilir.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                if monitor.volume != nil || monitor.manual {
                    Text("Monitör hoparlörü").foregroundStyle(Palette.secondary)
                    BlueSlider(value: monitor.volume ?? 0.5, enabled: !model.busy, label: "\(monitor.name) monitör hoparlörü") { model.writeDisplay(monitor.id, feature: "volume", value: $0) }
                    Toggle("Ortak sese bağla", isOn: Binding(get: { model.linkedMonitors.contains(monitor.id) }, set: { model.linkMonitor(monitor.id, enabled: $0) })).toggleStyle(.checkbox)
                }
            }
        }.font(.system(size: 12)).padding(.top, 3)
    }

    private var messageCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Palette.blue).accessibilityHidden(true)
            Text(model.message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.message = "" } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .accessibilityLabel("Bildirimi kapat").help("Bildirimi kapat")
        }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
    }

    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unison ayarları").font(.system(size: 16, weight: .semibold))
                    Text("Kontrol senin Mac'inde kalır.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button { settings = false } label: { ToolbarIcon(symbol: "xmark", tint: Palette.secondary) }.accessibilityLabel("Ayarları kapat")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Ses kontrolü").font(.system(size: 12, weight: .semibold))
                Button(engineActive ? "Yazılımsal sesi durdur" : "HDMI ve çoklu sesi etkinleştir") {
                    if engineActive { model.stopSoftwareAudio() } else { model.startSoftwareAudio() }
                }.foregroundStyle(Palette.blue)
                Text("Ses bu Mac'te işlenir; kaydedilmez veya gönderilmez.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Button(model.groupRunning ? "Donanım grubunu durdur" : "Donanım çoklu çıkışı kullan") {
                    if model.groupRunning { model.stopGroup() } else { model.startGroup() }
                }.disabled(!model.groupRunning && (model.selected.count < 2 || engineActive))
                Button(model.keysEnabled ? "F11/F12 · Ortak ses etkin" : "F11/F12 için erişilebilirlik izni ver") { model.enableKeys() }.disabled(model.keysEnabled)
            }
            Divider()
            Toggle("Girişte başlat", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) })).toggleStyle(.switch)
            Button { model.pollAudio(); Task { await model.refreshDisplays() } } label: {
                Label("Cihazları yenile", systemImage: "arrow.clockwise")
            }.disabled(model.busy)
            Divider()
            Button("Unison'dan çık") { model.stopSoftwareAudio(); if model.stopGroup() { NSApp.terminate(nil) } }
        }.font(.system(size: 12)).foregroundStyle(Palette.text).buttonStyle(PanelButtonStyle())
            .padding(20).frame(width: 320).background(Palette.background).preferredColorScheme(.dark)
    }

    private func icon(_ output: Output) -> String {
        if output.isAggregate { return "square.stack.3d.up" }
        if output.name.localizedCaseInsensitiveContains("MacBook") { return "laptopcomputer" }
        if model.monitors.contains(where: { !$0.builtIn && $0.name == output.name }) { return "display" }
        return "speaker.wave.2"
    }
    private func outputKind(_ output: Output) -> String {
        if output.name.localizedCaseInsensitiveContains("MacBook") { return "Yerleşik hoparlör" }
        if icon(output) == "display" { return "Ekran sesi" }
        return "Ses aygıtı"
    }
    private func rowBackground(active: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(active ? tint.opacity(0.075) : Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(active ? tint.opacity(0.30) : Palette.border))
    }
    private func emptyLabel(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(text).font(.system(size: 12))
        }.foregroundStyle(Palette.secondary).frame(maxWidth: .infinity).padding(18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
    }
}

private struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.unisonPreviewReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
            .background(configuration.isPressed ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct ToolbarIcon: View {
    let symbol: String
    let tint: Color
    @State private var hovering = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Palette.raised : Palette.surface))
            .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

private struct ControlIcon: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(tint)
            .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
    }
}

private struct DeviceBadge: View {
    let symbol: String
    let active: Bool
    let tint: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(active ? tint : Palette.secondary)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 11).fill(active ? tint.opacity(0.14) : Palette.raised))
            .overlay(alignment: .bottomTrailing) {
                if active {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.background, tint).offset(x: 3, y: 3)
                }
            }
    }
}

private struct Percentage: View {
    let value: Double?
    let tint: Color
    var prominent = false
    var body: some View {
        Text(value.map { "\(Int(($0.clamped * 100).rounded()))%" } ?? "—")
            .font(.system(size: prominent ? 16 : 11, weight: prominent ? .semibold : .medium, design: .rounded))
            .monospacedDigit().foregroundStyle(tint)
            .frame(width: prominent ? 48 : 33, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

struct BlueSlider: View {
    let value: Double
    var enabled = true
    var minimum: Double = 0
    let label: String
    var tint: Color = Palette.blue
    let action: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.unisonPreviewReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var draft: Double?
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geometry in
            let fraction = (draft ?? value).clamped
            let radius: CGFloat = 6
            let travel = max(1, geometry.size.width - radius * 2)
            let position = radius + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: 5)
                if enabled {
                    Capsule().fill(tint).frame(width: max(0, position), height: 5)
                    Circle().fill(Palette.text).overlay(Circle().stroke(tint, lineWidth: 2))
                        .frame(width: radius * 2, height: radius * 2)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .scaleEffect(draft != nil ? 1.2 : (hovering ? 1.1 : 1))
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
        }
        .frame(height: 24)
        .background(SliderScrollInput(value: draft ?? value, minimum: minimum, enabled: enabled, action: action))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .opacity(enabled ? 1 : 0.45)
        .focusable(enabled)
        .focusEffectDisabled()
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.text : .clear, lineWidth: 2).padding(-3).allowsHitTesting(false))
        .onKeyPress(.leftArrow) { adjust(-0.02) }
        .onKeyPress(.downArrow) { adjust(-0.02) }
        .onKeyPress(.rightArrow) { adjust(0.02) }
        .onKeyPress(.upArrow) { adjust(0.02) }
        .help(enabled ? "\(label): %\(Int((value.clamped * 100).rounded())) · Sürükle veya kaydır" : "\(label): Kullanılamıyor")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(enabled ? "%\(Int((value.clamped * 100).rounded()))" : "Kullanılamıyor")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            action(max(minimum, (value + (direction == .increment ? 0.05 : -0.05)).clamped))
        }
    }
    private func adjust(_ delta: Double) -> KeyPress.Result {
        guard enabled else { return .ignored }
        action(max(minimum, (value + delta).clamped))
        return .handled
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

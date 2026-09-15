import SwiftUI
import AppKit
import EQKit

struct EqualizerView: View {
    @ObservedObject var model: AppModel
    private let accent = Color.accentColor
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 20) {
                HStack {
                    Text("GRAPHIC EQUALIZER").font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Text("31 bands · ⅓ octave").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("GAIN / dB").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    let bandWidth = max(34, (geometry.size.width - 50) / 31)
                    let trackHeight = max(180, geometry.size.height - 58)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            scale(height: trackHeight).frame(width: 34)
                            ForEach(0..<31) { index in
                                band(index, height: trackHeight).frame(width: bandWidth)
                            }
                        }
                        .padding(.trailing, 12)
                    }
                }
                .frame(minHeight: 250)
                Divider()
                controls
            }
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            footer
        }
        .frame(minWidth: 1040, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("MultiBand EQ", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("MultiBand EQ").font(.system(size: 21, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(model.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(model.outputName)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(model.sampleRate / 1000, specifier: "%g") kHz")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.running {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.peak > 0.00001 ? String(format: "%.1f dBFS", 20 * log10(model.peak)) : "−∞ dBFS")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.clipping ? .orange : .secondary)
                    Text("OUTPUT PEAK").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(.tertiary)
                }.accessibilityElement(children: .combine).accessibilityLabel("Output peak")
            }
            if model.clipping {
                Label("Clipping — lower master gain", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            Toggle("Bypass", isOn: $model.bypassed).toggleStyle(.button).disabled(!model.running)
                .help("Hear the original sound without changing your curve")
            Button(action: model.toggleRunning) {
                Label(model.running ? "Stop EQ" : "Enable EQ", systemImage: "power").frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Process system audio through the current default output")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private func scale(height: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            ForEach([12,8,4,0,-4,-8,-12], id: \.self) { value in
                Text(value > 0 ? "+\(value)" : "\(value)")
                    .font(.system(size: 10, weight: value == 0 ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(value == 0 ? Color.primary : Color.secondary)
                    .position(x: 14, y: 10 + CGFloat(12 - value) / 24 * (height - 20))
            }
        }.frame(height: height)
    }
    private func band(_ index: Int, height: CGFloat) -> some View {
        let unavailable = EQState.frequencies[index] >= model.sampleRate / 2
        let selected = model.selectedBand == index
        return VStack(spacing: 7) {
            ZStack {
                VStack {
                    ForEach(0..<7) { tick in
                        Rectangle().fill(tick == 3 ? Color.primary.opacity(0.18) : Color.primary.opacity(0.055)).frame(height: 1)
                        if tick != 6 { Spacer(minLength: 0) }
                    }
                }.padding(.vertical, 10)
                BandSlider(value: Binding(get: { Double(model.gains[index]) }, set: { model.setGain(Float($0), band: index) }),
                           frequency: EQState.label(index), onSelect: { model.selectedBand = index })
                    .frame(width: 26, height: height)
                    .disabled(unavailable)
            }
            .frame(height: height)
            .background(selected ? accent.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5))
            GainField(value: Binding(get: { model.gains[index] }, set: { model.setGain($0, band: index) }),
                      range: -12...12, label: "\(EQState.label(index)) Hz gain")
                .disabled(unavailable)
            Text(EQState.label(index)).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? accent : .secondary)
        }
        .opacity(unavailable ? 0.4 : 1)
        .help(unavailable ? "Unavailable at this output sample rate; the saved value is preserved" : "\(EQState.label(index)) Hz · Double-click the fader to reset")
    }
    private var controls: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                controlLabel("PRESET")
                HStack(spacing: 6) {
                    Button("Import…", action: model.importPreset)
                    Button("Export…", action: model.exportPreset)
                    Button("Reset", action: model.reset).help("Reset all bands and master gain to 0 dB")
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                controlLabel("CHANNELS")
                HStack(spacing: 6) {
                    Picker("Mode", selection: Binding(get: { model.session.draft.mode }, set: model.setMode)) {
                        ForEach(ChannelMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 155)
                    if model.session.draft.mode == .independent {
                        Picker("Channel", selection: $model.rightChannel) {
                            Text("L").tag(false); Text("R").tag(true)
                        }.pickerStyle(.segmented).frame(width: 66)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                controlLabel("SELECTED BAND")
                HStack(spacing: 5) {
                    Picker("Band", selection: $model.selectedBand) {
                        ForEach(0..<31) { Text("\(EQState.label($0)) Hz").tag($0) }
                    }.labelsHidden().frame(width: 89)
                    GainField(value: Binding(get: { model.gains[model.selectedBand] }, set: { model.setGain($0, band: model.selectedBand) }),
                              range: -12...12, label: "Selected band gain")
                        .frame(width: 48)
                        .disabled(EQState.frequencies[model.selectedBand] >= model.sampleRate / 2)
                    Text("dB").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 9) {
                controlLabel("MASTER GAIN")
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(model.session.draft.master) }, set: { model.setMaster(Float($0)) }), in: -24...12, step: 0.1)
                        .frame(minWidth: 100, maxWidth: 180).accessibilityLabel("Master gain")
                    GainField(value: Binding(get: { model.session.draft.master }, set: model.setMaster), range: -24...12, label: "Master gain")
                        .frame(width: 48)
                    Text("dB").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.controlSize(.small)
    }
    private func controlLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Live preview", isOn: $model.session.livePreview).toggleStyle(.checkbox)
                .help("When off, changes are heard only after Apply")
            Text(model.session.hasChanges ? "Unsaved changes" : "All changes saved")
                .foregroundStyle(.secondary).font(.system(size: 11))
            Spacer()
            Text(model.running ? (model.bypassed ? "Bypassed" : "Processing system audio") : "Enable EQ to process system audio")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Cancel", action: model.cancel).disabled(!model.session.hasChanges)
                .keyboardShortcut(.cancelAction)
            Button("Apply", action: model.apply).disabled(!model.session.hasChanges)
                .keyboardShortcut("s", modifiers: .command)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

struct GainField: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var label: String
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.vertical, 4)
            .background(focused ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .onAppear { text = EQState.db(value) }
            .onChange(of: value) { _, newValue in if !focused { text = EQState.db(newValue) } }
            .onChange(of: text) { _, _ in
                // Keep a valid edit in the model immediately, including before clicking Apply.
                if focused, let parsed = parsedValue, range.contains(parsed) {
                    value = (parsed * 10).rounded() / 10
                }
            }
            .onChange(of: focused) { _, newValue in if !newValue { commit() } }
            .onSubmit { commit(); focused = false }
            .onExitCommand { text = EQState.db(value); focused = false }
            .accessibilityLabel(label).accessibilityValue("\(EQState.db(value)) decibels")
    }
    private var parsedValue: Float? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        if Locale.current.decimalSeparator == "," { normalized = normalized.replacingOccurrences(of: ",", with: ".") }
        guard let parsed = Float(normalized), parsed.isFinite else { return nil }
        return parsed
    }
    private func commit() {
        if let parsed = parsedValue {
            value = (min(range.upperBound, max(range.lowerBound, parsed)) * 10).rounded() / 10
        } else { NSSound.beep() }
        text = EQState.db(value)
    }
}

struct BandSlider: NSViewRepresentable {
    @Binding var value: Double
    var frequency: String
    var onSelect: () -> Void
    func makeNSView(context: Context) -> PrecisionSlider {
        let slider = PrecisionSlider()
        slider.minValue = -12; slider.maxValue = 12; slider.sliderType = .linear
        slider.isVertical = true
        slider.isContinuous = true; slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onSelect = onSelect
        slider.setAccessibilityLabel("\(frequency) Hz")
        return slider
    }
    func updateNSView(_ slider: PrecisionSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        slider.onSelect = onSelect
        slider.setAccessibilityValueDescription("\(EQState.db(Float(value))) decibels")
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: BandSlider
        init(_ parent: BandSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = (sender.doubleValue * 10).rounded() / 10 }
    }
}

final class PrecisionSlider: NSSlider {
    var onSelect: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?()
        if event.clickCount == 2 { doubleValue = 0; sendAction(action, to: target) }
        else { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let direction: Double
        switch event.keyCode {
        case 126, 124: direction = 1
        case 125, 123: direction = -1
        default: super.keyDown(with: event); return
        }
        onSelect?()
        let amount = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * amount))
        sendAction(action, to: target)
    }
}

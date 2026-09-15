import AppKit
import Combine
import CoreAudio
import EQKit
import UniformTypeIdentifiers

/// Meter changes should invalidate only the meter, not the entire slider editor.
@MainActor
final class OutputMeter: ObservableObject {
    @Published private(set) var peak: Float = 0
    @Published private(set) var clipping = false

    func update(peak: Float, clipping: Bool) {
        if self.peak != peak { self.peak = peak }
        if self.clipping != clipping { self.clipping = clipping }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: EditingSession { didSet { sendParameters() } }
    @Published var rightChannel = false
    @Published var selectedBand = 17
    @Published private(set) var running = false
    @Published var bypassed = false { didSet { sendParameters() } }
    @Published private(set) var outputName = "System default output"
    @Published private(set) var sampleRate: Double = 48000
    @Published private(set) var bufferFrames: UInt32 = 0
    let meter = OutputMeter()
    @Published var error: String?
    private let audio = SystemAudio()
    private var timer: AnyCancellable?
    private var parametersPending = false
    private var lastCallbacks: UInt64 = 0
    private var lastCallbackTime = Date()
    private var clippingUntil = Date.distantPast
    private var resumeAfterSleep = false
    private let settingsKey = "MultiBandEQ.committed.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey) {
            do { session = EditingSession(try EQPreset.decode(data)) }
            catch { session = EditingSession(); self.error = "Saved settings could not be loaded. A flat curve was restored. \(error.localizedDescription)" }
        } else { session = EditingSession() }
        refreshOutput()
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.tick()
        }
    }
    var gains: [Float] { rightChannel && session.draft.mode == .independent ? session.draft.right : session.draft.left }
    var effectiveState: EQState { bypassed ? EQState() : session.rendered }
    func setGain(_ value: Float, band: Int) {
        selectedBand = band
        session.draft.setGain(value, band: band, rightChannel: rightChannel)
    }
    func setMaster(_ value: Float) {
        guard value.isFinite else { return }
        session.draft.master = (min(12, max(-24, value)) * 10).rounded() / 10
    }
    func setMode(_ mode: ChannelMode) { session.draft.setMode(mode, fromRight: rightChannel) }
    func reset() {
        let mode = session.draft.mode
        var flat = EQState(); flat.mode = mode
        session.draft = flat
    }
    func apply() {
        do {
            let data = try EQPreset(settings: session.draft).encoded()
            UserDefaults.standard.set(data, forKey: settingsKey)
            session.apply()
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { session.cancel() }
    func start() {
        error = nil
        do {
            try audio.start(state: effectiveState)
            outputName = audio.outputName; sampleRate = audio.sampleRate; bufferFrames = audio.bufferFrames
            running = true; lastCallbacks = 0; lastCallbackTime = Date()
        } catch { running = false; self.error = error.localizedDescription }
    }
    func stop() {
        audio.stop(); running = false; meter.update(peak: 0, clipping: false); clippingUntil = .distantPast
    }
    func toggleRunning() { running ? stop() : start() }
    func willSleep() { resumeAfterSleep = running; stop() }
    func didWake() {
        guard resumeAfterSleep else { return }
        resumeAfterSleep = false
        // Allow HAL to publish the output after wake; no automatic retries after failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }
    private func sendParameters() { parametersPending = !audio.update(effectiveState) }
    private func refreshOutput() {
        if let device = try? HAL.defaultOutput() {
            let name = (try? HAL.string(device, kAudioObjectPropertyName)) ?? "System default output"
            let rate = (try? HAL.sampleRate(device)) ?? 48000
            // @Published emits even for equal assignments; avoid idle editor relayouts.
            if outputName != name { outputName = name }
            if sampleRate != rate { sampleRate = rate }
        }
    }
    private func tick() {
        guard running else { refreshOutput(); return }
        if audio.routeChanged() { start(); return }
        if parametersPending { sendParameters() }
        let peak = audio.takePeak()
        if peak > 1 { clippingUntil = Date().addingTimeInterval(1.5) }
        meter.update(peak: peak, clipping: Date() < clippingUntil)
        let callbacks = audio.callbacks
        if callbacks != lastCallbacks { lastCallbacks = callbacks; lastCallbackTime = Date() }
        if audio.faults > 0 || Date().timeIntervalSince(lastCallbackTime) > 3 {
            stop()
            error = "The audio route stopped delivering usable buffers. Ordinary playback has been restored. Check capture permission and the selected output, then enable EQ again."
        }
    }
    func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import EQ preset"; panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_000_000 else { throw PresetError.tooLarge }
            session.draft = try EQPreset.decode(Data(contentsOf: url))
        } catch { self.error = "Could not import preset. \(error.localizedDescription)" }
    }
    func exportPreset() {
        let panel = NSSavePanel()
        panel.title = "Export EQ preset"; panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "My Equalizer.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try EQPreset(settings: session.draft).encoded().write(to: url, options: .atomic) }
        catch { self.error = "Could not export preset. \(error.localizedDescription)" }
    }
}

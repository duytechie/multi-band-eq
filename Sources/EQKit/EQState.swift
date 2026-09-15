import Foundation

public enum ChannelMode: String, Codable, CaseIterable, Sendable {
    case linked, independent
    public var title: String { self == .linked ? "Stereo linked" : "Independent L / R" }
}

public struct EQState: Codable, Equatable, Sendable {
    public static let frequencies: [Double] = [
        20,25,31.5,40,50,63,80,100,125,160,200,250,315,400,500,630,
        800,1000,1250,1600,2000,2500,3150,4000,5000,6300,8000,10000,12500,16000,20000
    ]
    public var left: [Float]
    public var right: [Float]
    public var master: Float
    public var mode: ChannelMode

    public init() {
        left = Array(repeating: 0, count: 31); right = left; master = 0; mode = .linked
    }
    public static func label(_ index: Int) -> String {
        let value = frequencies[index]
        return value >= 1000 ? String(format: "%gk", value / 1000) : String(format: "%g", value)
    }
    public static func db(_ value: Float) -> String { String(format: "%+.1f", abs(value) < 0.05 ? 0 : value) }
    public mutating func setGain(_ value: Float, band: Int, rightChannel: Bool) {
        guard left.indices.contains(band), value.isFinite else { return }
        let gain = (min(12, max(-12, value)) * 10).rounded() / 10
        if mode == .linked { left[band] = gain; right[band] = gain }
        else if rightChannel { right[band] = gain } else { left[band] = gain }
    }
    public mutating func setMode(_ newMode: ChannelMode, fromRight: Bool) {
        if newMode == .linked {
            let source = fromRight ? right : left
            left = source; right = source
        }
        mode = newMode
    }
    public func validated() throws -> EQState {
        guard left.count == 31, right.count == 31 else { throw PresetError.invalidBands }
        guard (left + right).allSatisfy({ $0.isFinite && (-12...12).contains($0) }),
              master.isFinite, (-24...12).contains(master) else { throw PresetError.invalidGain }
        guard mode != .linked || left == right else { throw PresetError.invalidLinkedCurve }
        return self
    }
}

public enum PresetError: LocalizedError {
    case invalidBands, invalidGain, invalidVersion, invalidLinkedCurve, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidBands: return "The preset must contain the 31 supported frequencies and two 31-band curves."
        case .invalidGain: return "Band gains must be finite values between −12 and +12 dB; master gain must be between −24 and +12 dB."
        case .invalidVersion: return "This preset version is not supported."
        case .invalidLinkedCurve: return "A stereo-linked preset must have identical left and right curves."
        case .tooLarge: return "The preset is too large. Choose a MultiBand EQ JSON preset smaller than 1 MB."
        }
    }
}

public struct EQPreset: Codable {
    public var version: Int
    public var frequencies: [Double]
    public var settings: EQState
    public init(settings: EQState) { version = 1; frequencies = EQState.frequencies; self.settings = settings }
    public static func decode(_ data: Data) throws -> EQState {
        guard data.count <= 1_000_000 else { throw PresetError.tooLarge }
        let preset = try JSONDecoder().decode(Self.self, from: data)
        guard preset.version == 1 else { throw PresetError.invalidVersion }
        guard preset.frequencies == EQState.frequencies else { throw PresetError.invalidBands }
        return try preset.settings.validated()
    }
    public func encoded() throws -> Data {
        _ = try settings.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct EditingSession {
    public private(set) var committed: EQState
    public var draft: EQState
    public var livePreview = true
    public var rendered: EQState { livePreview ? draft : committed }
    public var hasChanges: Bool { draft != committed }
    public init(_ state: EQState = EQState()) { committed = state; draft = state }
    public mutating func apply() { committed = draft }
    public mutating func cancel() { draft = committed }
}

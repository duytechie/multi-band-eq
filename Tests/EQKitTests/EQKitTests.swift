import XCTest
@testable import EQKit
import EQDSP

final class EQStateTests: XCTestCase {
    func testGainEditingAndChannelModes() {
        var state = EQState()
        state.setGain(4.26, band: 17, rightChannel: false)
        XCTAssertEqual(state.left[17], 4.3); XCTAssertEqual(state.right[17], 4.3)
        state.setMode(.independent, fromRight: false)
        state.setGain(-30, band: 17, rightChannel: true)
        XCTAssertEqual(state.right[17], -12); XCTAssertEqual(state.left[17], 4.3)
        state.setGain(.nan, band: 17, rightChannel: false)
        XCTAssertEqual(state.left[17], 4.3)
        state.setMode(.linked, fromRight: true)
        XCTAssertEqual(state.left, state.right)
        XCTAssertEqual(EQState.db(-0.001), "+0.0")
    }
    func testPreviewApplyCancelTransaction() {
        var editor = EditingSession()
        editor.draft.setGain(3, band: 0, rightChannel: false)
        XCTAssertEqual(editor.rendered.left[0], 3)
        editor.livePreview = false
        XCTAssertEqual(editor.rendered.left[0], 0)
        editor.apply()
        XCTAssertEqual(editor.rendered.left[0], 3)
        editor.livePreview = true
        editor.draft.setGain(8, band: 0, rightChannel: false)
        editor.cancel()
        XCTAssertEqual(editor.rendered.left[0], 3)
        XCTAssertFalse(editor.hasChanges)
    }
    func testPresetRoundTripAndValidation() throws {
        var state = EQState(); state.mode = .independent; state.right[30] = -6.2; state.master = -9
        XCTAssertEqual(try EQPreset.decode(EQPreset(settings: state).encoded()), state)
        var preset = EQPreset(settings: state)
        preset.version = 99
        XCTAssertThrowsError(try EQPreset.decode(JSONEncoder().encode(preset)))
        preset.version = 1; preset.frequencies[0] = 21
        XCTAssertThrowsError(try EQPreset.decode(JSONEncoder().encode(preset)))
        preset = EQPreset(settings: state); preset.settings.left.removeLast()
        XCTAssertThrowsError(try EQPreset.decode(JSONEncoder().encode(preset)))
        preset.settings = state; preset.settings.left[0] = 99
        XCTAssertThrowsError(try EQPreset.decode(JSONEncoder().encode(preset)))
        preset.settings = state; preset.settings.mode = .linked
        XCTAssertThrowsError(try EQPreset.decode(JSONEncoder().encode(preset)))
        XCTAssertThrowsError(try EQPreset.decode(Data("not JSON".utf8)))
    }
}

final class DSPTests: XCTestCase {
    private func render(_ processor: OpaquePointer, left: [Float], right: [Float]) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: left.count), r = l
        EQProcess(processor, left, right, &l, &r, UInt32(left.count))
        return (l, r)
    }
    private func gainDB(_ output: [Float], reference: [Float]) -> Double {
        let begin = output.count / 2
        let power = output[begin...].reduce(0.0) { $0 + Double($1) * Double($1) }
        let base = reference[begin...].reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(power / base)
    }
    func testFlatImpulseAndStereoIsolation() throws {
        let p = try XCTUnwrap(EQCreate(48000, 0)); defer { EQDestroy(p) }
        var impulse = [Float](repeating: 0, count: 4096); impulse[0] = 0.5
        let silent = [Float](repeating: 0, count: impulse.count)
        let result = render(p, left: impulse, right: silent)
        XCTAssertEqual(result.0, impulse); XCTAssertEqual(result.1, silent)
    }
    func testEveryBandCenterAtSupportedSampleRates() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            for (band, frequency) in EQState.frequencies.enumerated() {
                let p = try XCTUnwrap(EQCreate(rate, 0)); defer { EQDestroy(p) }
                var gains = [Float](repeating: 0, count: 31); gains[band] = 6
                let flat = [Float](repeating: 0, count: 31)
                XCTAssertTrue(EQSetGains(p, gains, flat, 0))
                // Allow at least 40 cycles for the narrow bass filters to settle.
                let count = Int(rate * max(0.5, 40 / frequency))
                let input = (0..<count).map { Float(0.05 * sin(2 * .pi * frequency * Double($0) / rate)) }
                let result = render(p, left: input, right: input)
                XCTAssertEqual(gainDB(result.0, reference: input), 6, accuracy: 0.12, "\(frequency) Hz at \(rate)")
                XCTAssertEqual(gainDB(result.1, reference: input), 0, accuracy: 0.0001)
            }
        }
    }
    func testCutMasterGainAndNyquistBandBypass() throws {
        let p = try XCTUnwrap(EQCreate(32000, 0)); defer { EQDestroy(p) }
        var left = [Float](repeating: 0, count: 31); left[17] = -6; left[30] = 12; left[29] = 12
        let right = [Float](repeating: 0, count: 31)
        XCTAssertTrue(EQSetGains(p, left, right, -3))
        let input = (0..<16000).map { Float(0.1 * sin(2 * .pi * 1000 * Double($0) / 32000)) }
        let result = render(p, left: input, right: input)
        XCTAssertEqual(gainDB(result.0, reference: input), -9, accuracy: 0.03)
        XCTAssertEqual(gainDB(result.1, reference: input), -3, accuracy: 0.03)
    }
    func testQueueIsBoundedAndLatestPublishedStateWins() throws {
        let p = try XCTUnwrap(EQCreate(48000, 0)); defer { EQDestroy(p) }
        let flat = [Float](repeating: 0, count: 31)
        for i in 0..<7 { XCTAssertTrue(EQSetGains(p, flat, flat, Float(-i))) }
        XCTAssertFalse(EQSetGains(p, flat, flat, 12))
        let input = [Float](repeating: 0.1, count: 2048)
        let result = render(p, left: input, right: input)
        XCTAssertEqual(gainDB(result.0, reference: input), -6, accuracy: 0.01)
        XCTAssertTrue(EQSetGains(p, flat, flat, 0))
    }
    func testChangingCurvesRemainFiniteAndReportClipping() throws {
        let p = try XCTUnwrap(EQCreate(48000, 0)); defer { EQDestroy(p) }
        var input = [Float](repeating: 0, count: 256)
        for block in 0..<400 {
            let gains = (0..<31).map { Float(($0 + block) % 2 == 0 ? 12 : -12) }
            XCTAssertTrue(EQSetGains(p, gains, gains, block % 2 == 0 ? 12 : -24))
            for i in input.indices { input[i] = Float(sin(Double(block * 256 + i) * 0.13)) }
            let result = render(p, left: input, right: input)
            XCTAssertTrue(result.0.allSatisfy { $0.isFinite && abs($0) < 1000 })
        }
        XCTAssertGreaterThan(EQTakePeak(p), 1)
        XCTAssertEqual(EQTakePeak(p), 0)
        XCTAssertEqual(EQFaultCount(p), 0)
    }
    func testCallbackSelectsTapAfterHardwareInputs() throws {
        let p = try XCTUnwrap(EQCreate(48000, 2)); defer { EQDestroy(p) }
        var input: [Float] = [99, 99, 0.1, 0.2, 99, 99, 0.3, 0.4]
        var output = [Float](repeating: -1, count: 4)
        var timestamp = AudioTimeStamp()
        input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                withUnsafePointer(to: &timestamp) { time in
                    XCTAssertEqual(EQDeviceIO(0, time, &inList, time, &outList, time, UnsafeMutableRawPointer(p)), 0)
                }
            }
        }
        XCTAssertEqual(output, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(EQCallbackCount(p), 1); XCTAssertEqual(EQFaultCount(p), 0)
    }
}

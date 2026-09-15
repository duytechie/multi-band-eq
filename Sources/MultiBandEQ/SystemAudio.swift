import Foundation
import CoreAudio
import EQDSP
import EQKit

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioFailure(message: "\(operation) failed (Core Audio \(status)). If capture access was denied, allow MultiBand EQ in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        }
    }
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var address = address(selector, scope), size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Reading audio device")
        }
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        try read(object, selector, into: &value)
        return value as String
    }
    static func streams(_ object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        var address = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading audio streams")
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes { bytes in
                try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "Reading audio streams")
            }
        }
        return ids
    }
    static func formats(_ object: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        try streams(object, scope: scope).map { id in
            var format = AudioStreamBasicDescription()
            try read(id, kAudioStreamPropertyVirtualFormat, into: &format)
            return format
        }
    }
    static func defaultOutput() throws -> AudioObjectID {
        var device: AudioObjectID = 0
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device)
        guard device != 0 else { throw AudioFailure(message: "No audio output is available. Connect headphones or choose an output in System Settings.") }
        return device
    }
    static func sampleRate(_ device: AudioObjectID) throws -> Double {
        var value: Double = 0
        try read(device, kAudioDevicePropertyNominalSampleRate, into: &value)
        return value
    }
    static func selfProcess() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid(), object: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "Finding this app's audio process")
        guard object != 0 else { throw AudioFailure(message: "Core Audio could not identify this app. Restart it before enabling capture.") }
        return object
    }
}

/// All lifetime and parameter writes run on the main actor. Only EQDeviceIO touches DSP render state.
@MainActor
final class SystemAudio {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var processor: OpaquePointer?
    private(set) var outputDevice: AudioObjectID = 0
    private(set) var outputName = "Default output"
    private(set) var sampleRate: Double = 48000
    private(set) var bufferFrames: UInt32 = 0
    var isRunning: Bool { ioProc != nil && processor != nil }
    var callbacks: UInt64 { EQCallbackCount(processor) }
    var faults: UInt64 { EQFaultCount(processor) }
    func takePeak() -> Float { EQTakePeak(processor) }

    func start(state: EQState) throws {
        stop()
        do {
            outputDevice = try HAL.defaultOutput()
            let uid = try HAL.string(outputDevice, kAudioDevicePropertyDeviceUID)
            outputName = try HAL.string(outputDevice, kAudioObjectPropertyName)
            sampleRate = try HAL.sampleRate(outputDevice)
            let hardwareOutputs = try HAL.formats(outputDevice, scope: kAudioDevicePropertyScopeOutput)
            guard hardwareOutputs.reduce(0, { $0 + $1.mChannelsPerFrame }) == 2 else {
                throw AudioFailure(message: "Choose a stereo output device. This version supports two-channel outputs; multichannel and mono routes are not yet supported.")
            }
            let hardwareInputs = try HAL.formats(outputDevice, scope: kAudioDevicePropertyScopeInput)
            let hardwareInputChannels = hardwareInputs.reduce(UInt32(0)) { $0 + $1.mChannelsPerFrame }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try HAL.selfProcess()])
            description.name = "MultiBand EQ capture"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Creating system audio capture")

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MultiBand EQ (private)",
                kAudioAggregateDeviceUIDKey: "com.tomh.multi-band-eq.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Creating audio route")
            // Device output is the aggregate's clock source; HAL drift-compensates the tap.
            var rate = sampleRate
            var rateAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
            try HAL.check(AudioObjectSetPropertyData(aggregate, &rateAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &rate), "Configuring audio sample rate")
            let inputs = try HAL.formats(aggregate, scope: kAudioDevicePropertyScopeInput)
            let outputs = try HAL.formats(aggregate, scope: kAudioDevicePropertyScopeOutput)
            // Aggregate device streams are ordered: hardware subdevices, followed by sub-taps.
            // Validate the boundary so a hardware input can never be mistaken for captured audio.
            guard inputs.count == hardwareInputs.count + 1,
                  inputs.last?.mChannelsPerFrame == 2,
                  inputs.dropLast().reduce(UInt32(0), { $0 + $1.mChannelsPerFrame }) == hardwareInputChannels,
                  outputs.reduce(UInt32(0), { $0 + $1.mChannelsPerFrame }) == 2 else {
                throw AudioFailure(message: "This device exposes an unsupported audio stream layout. Ordinary playback has been restored.")
            }
            for format in [inputs.last! /* only the tap input is read */] + outputs {
                guard format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                      format.mBitsPerChannel == 32,
                      abs(format.mSampleRate - sampleRate) < 1 else {
                    throw AudioFailure(message: "This route does not provide synchronized 32-bit floating-point audio. Choose another stereo output.")
                }
            }
            guard let created = EQCreate(sampleRate, hardwareInputChannels) else {
                throw AudioFailure(message: "Could not initialize the equalizer for this sample rate.")
            }
            processor = created
            _ = update(state)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, EQDeviceIO, UnsafeMutableRawPointer(created), &ioProc), "Preparing audio playback")
            try disableHardwareInputs(streamCount: inputs.count)
            try HAL.read(aggregate, kAudioDevicePropertyBufferFrameSize, into: &bufferFrames)
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Starting system audio capture")
        } catch {
            stop()
            throw error
        }
    }

    private func disableHardwareInputs(streamCount: Int) throws {
        guard streamCount > 1 else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = offset + streamCount * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc!, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)[streamCount - 1] = 1
        var address = HAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeInput)
        try HAL.check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), storage), "Disabling unused hardware inputs")
    }

    @discardableResult func update(_ state: EQState) -> Bool {
        guard let processor else { return true }
        return state.left.withUnsafeBufferPointer { left in
            (state.mode == .linked ? state.left : state.right).withUnsafeBufferPointer { right in
                EQSetGains(processor, left.baseAddress!, right.baseAddress!, state.master)
            }
        }
    }

    func stop() {
        // Stop and detach the callback before freeing its context. Then destroy the private route.
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let processor { EQDestroy(processor) }
        processor = nil
    }

    func routeChanged() -> Bool {
        guard let device = try? HAL.defaultOutput(), device == outputDevice,
              let rate = try? HAL.sampleRate(device), abs(rate - sampleRate) < 1 else { return true }
        var alive: UInt32 = 0
        try? HAL.read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive)
        return alive == 0
    }
}

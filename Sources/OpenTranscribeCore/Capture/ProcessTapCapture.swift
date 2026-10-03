import Foundation
import AVFoundation
import CoreAudio

public enum ProcessTapError: Error, Sendable, Equatable {
    case coreAudio(OSStatus, String)
    case processNotFound
    case formatUnavailable
    case converterUnavailable
    case alreadyRunning
}

/// Captures a single meeting app's audio output via a CoreAudio Process Tap, converted to
/// 16 kHz mono Float32. Reference pattern: insidegui/AudioCap (BSD-2), reimplemented here
/// against the real `AudioHardwareTapping.h` / `CATapDescription` API rather than a copy.
///
/// A process tap alone has no clock; it must be attached to a private aggregate device, which
/// is what actually gets an `AudioDeviceIOProcID`. If the app-scoped tap fails to build (the
/// app isn't producing a process object, e.g. it hasn't opened an output stream yet), this
/// falls back to a global tap that excludes this process's own audio.
public final class ProcessTapCapture: CaptureSource, @unchecked Sendable {
    private let targetApp: MeetingApp
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.opentranscribe.processtap.io")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    public init(app: MeetingApp) {
        self.targetApp = app
    }

    public func start(onSamples: @escaping @Sendable ([Float]) async -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard aggregateDeviceID == AudioObjectID(kAudioObjectUnknown) else {
            throw ProcessTapError.alreadyRunning
        }

        let description = try makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        try Self.check(createStatus, "AudioHardwareCreateProcessTap")
        tapID = newTapID

        let asbd = try Self.tapStreamFormat(tapID: newTapID)
        var mutableASBD = asbd
        guard let sourceFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw ProcessTapError.formatUnavailable
        }
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw ProcessTapError.converterUnavailable
        }

        do {
            let deviceID = try Self.createAggregateDevice(tapUID: description.uuid.uuidString)
            aggregateDeviceID = deviceID

            var newIOProcID: AudioDeviceIOProcID?
            // The IOBlock is a synchronous realtime-thread callback, so bridge into the async
            // `onSamples` via an unstructured Task instead of blocking that thread.
            let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
                guard
                    let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: sourceFormat, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                if let samples = Self.convert(inputBuffer, using: converter, targetFormat: targetFormat) {
                    Task { await onSamples(samples) }
                }
            }
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, deviceID, ioQueue, ioBlock)
            try Self.check(ioStatus, "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = newIOProcID

            let startStatus = AudioDeviceStart(deviceID, newIOProcID)
            try Self.check(startStatus, "AudioDeviceStart")
        } catch {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
        if let ioProcID {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }

        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Tap description

    private func makeTapDescription() throws -> CATapDescription {
        // Chrome, Slack and Discord split mic input and audio output across different processes
        // of the same app (a helper holds the mic, a renderer or the audio service renders
        // sound). Tapping only the pid detection saw holding the mic therefore often taps a
        // process that never outputs anything. Taking every process in the same bundle-id
        // family covers both, and `monoMixdownOfProcesses` happily mixes several down to one.
        let familyIDs = Self.familyProcessObjectIDs(bundleID: targetApp.bundleID)
        if !familyIDs.isEmpty {
            let description = CATapDescription(monoMixdownOfProcesses: familyIDs)
            description.name = "OpenTranscribe-\(targetApp.bundleID)"
            description.isPrivate = true
            return description
        }
        if let processID = try? Self.processObjectID(forPID: targetApp.pid) {
            let description = CATapDescription(monoMixdownOfProcesses: [processID])
            description.name = "OpenTranscribe-\(targetApp.bundleID)"
            description.isPrivate = true
            return description
        }
        // Fallback: tap everything on the system except this very process, so at least the
        // meeting audio (mixed with whatever else plays) still gets captured.
        let ownID = try Self.processObjectID(forPID: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownID])
        description.name = "OpenTranscribe-fallback"
        description.isPrivate = true
        return description
    }

    /// Every currently running CoreAudio process object whose bundle id is `bundleID` or a
    /// child of it (`bundleID.hasPrefix(bundleID + ".")`), mirroring `DetectionSettings.trigger`'s
    /// parent-child matching so the tap and the detector agree on what counts as "the app".
    private static func familyProcessObjectIDs(bundleID: String) -> [AudioObjectID] {
        guard let all = try? CoreAudioProcessDirectory.allObjectIDs() else { return [] }
        return all.filter { objectID in
            guard let candidate = try? CoreAudioProcessDirectory.bundleID(for: objectID) else { return false }
            return candidate == bundleID || candidate.hasPrefix(bundleID + ".")
        }
    }

    // MARK: - CoreAudio helpers

    private static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw ProcessTapError.coreAudio(status, context) }
    }

    private static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidVar = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidVar,
            &dataSize, &objectID)
        try check(status, "TranslatePIDToProcessObject")
        guard objectID != AudioObjectID(kAudioObjectUnknown) else { throw ProcessTapError.processNotFound }
        return objectID
    }

    private static func tapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        try check(status, "TapPropertyFormat")
        return asbd
    }

    /// Builds a private, tap-only aggregate device (no real subdevices) so the tap gets an
    /// IO clock without ever touching the user's actual output routing.
    private static func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenTranscribe-\(aggregateUID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        try check(status, "AudioHardwareCreateAggregateDevice")
        return deviceID
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        // The conversion runs synchronously inside `convert(to:error:)` before this function
        // returns, so a class box is enough to satisfy Sendable checking without implying any
        // real concurrent access to the buffer or the "already consumed" flag.
        let box = ConversionInputBox(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if box.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            box.consumed = true
            inputStatus.pointee = .haveData
            return box.buffer
        }
        guard status != .error, let channelData = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}

/// Carries a single input buffer through an `AVAudioConverter` input callback. The callback is
/// invoked synchronously and exactly once per conversion here, never actually concurrently.
private final class ConversionInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

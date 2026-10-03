import Foundation
import AVFoundation
import Testing

@testable import OpenTranscribeCore

// MARK: - PrerollBuffer

@Suite("PrerollBuffer")
struct PrerollBufferTests {
    @Test func appendsAndPeeksInOrder() {
        var buffer = PrerollBuffer(seconds: 1) // 16_000 samples capacity
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        #expect(buffer.peek() == [1, 2, 3, 4, 5])
        #expect(buffer.storedCount == 5)
    }

    @Test func overflowDropsOldestSamples() {
        var buffer = PrerollBuffer(seconds: Double(5) / PrerollBuffer.sampleRate) // capacity 5
        buffer.append([1, 2, 3, 4, 5])
        buffer.append([6, 7])
        #expect(buffer.peek() == [3, 4, 5, 6, 7])
        #expect(buffer.storedCount == 5)
    }

    @Test func singleChunkLargerThanCapacityKeepsOnlyTail() {
        var buffer = PrerollBuffer(seconds: Double(3) / PrerollBuffer.sampleRate) // capacity 3
        buffer.append([1, 2, 3, 4, 5])
        #expect(buffer.peek() == [3, 4, 5])
    }

    @Test func drainEmptiesTheBuffer() {
        var buffer = PrerollBuffer(seconds: 1)
        buffer.append([1, 2, 3])
        let drained = buffer.drain()
        #expect(drained == [1, 2, 3])
        #expect(buffer.storedCount == 0)
        #expect(buffer.peek().isEmpty)
    }

    @Test func emptyAppendIsNoOp() {
        var buffer = PrerollBuffer(seconds: 1)
        buffer.append([])
        #expect(buffer.storedCount == 0)
    }
}

// MARK: - WAVWriter

@Suite("WAVWriter")
struct WAVWriterTests {
    @Test func roundTripsThroughAVAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        let samples: [Float] = (0..<1_600).map { Float(sin(Double($0) * 0.1)) }
        try await writer.write(Array(samples[0..<800]))
        try await writer.write(Array(samples[800..<1_600]))
        await writer.close()

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 1_600)
        #expect(readBack.fileFormat.sampleRate == 16_000)
        #expect(readBack.fileFormat.channelCount == 1)

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: readBack.processingFormat, frameCapacity: AVAudioFrameCount(readBack.length))
        else {
            Issue.record("could not allocate read buffer")
            return
        }
        try readBack.read(into: buffer)
        #expect(buffer.frameLength == 1_600)
    }

    @Test func lengthIsReadableWithoutClosing() async throws {
        // Simulates a hard-killed daemon: the header must already claim the right length
        // before `close()` ever runs, or a crash leaves a file no reader can open correctly.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-unclosed-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        let samples: [Float] = (0..<3_200).map { Float(sin(Double($0) * 0.1)) }
        try await writer.write(Array(samples[0..<1_600]))
        try await writer.write(Array(samples[1_600..<3_200]))
        // No `writer.close()` — the file handle inside WAVWriter is never released.

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 3_200)
    }

    @Test func writeAfterCloseIsNoOp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-closed-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        try await writer.write([0, 0, 0])
        await writer.close()
        try await writer.write([1, 1, 1]) // must not throw or reopen the file

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 3)
    }
}

// MARK: - AudioCaptureCoordinator

/// Scripted fake so tests never touch CoreAudio or AVAudioEngine hardware.
private final class FakeCaptureSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable ([Float]) async -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?

    func start(onSamples: @escaping @Sendable ([Float]) async -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if let startError { throw startError }
        callback = onSamples
        startCount += 1
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        stopCount += 1
    }

    /// Simulates hardware delivering a chunk of audio. Unlike the real, realtime-thread-bound
    /// sources, this awaits ingestion directly so tests get deterministic ordering.
    func push(_ samples: [Float]) async {
        await currentCallback()?(samples)
    }

    private func currentCallback() -> (@Sendable ([Float]) async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return callback
    }
}

@Suite("AudioCaptureCoordinator")
struct AudioCaptureCoordinatorTests {
    private func makeCoordinator(root: URL) -> (AudioCaptureCoordinator, FakeCaptureSource, FakeCaptureSource) {
        let mic = FakeCaptureSource()
        let remote = FakeCaptureSource()
        let paths = Paths(root: root, wikiRaw: root.appendingPathComponent("wiki"))
        let coordinator = AudioCaptureCoordinator(
            paths: paths,
            prerollSeconds: 1,
            makeMicSource: { mic },
            makeRemoteSource: { _ in remote }
        )
        return (coordinator, mic, remote)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ot-coordinator-\(UUID().uuidString)")
    }

    private var app: MeetingApp { MeetingApp(bundleID: "us.zoom.xos", name: "Zoom", pid: 1234) }

    @Test func discardPrerollWritesNothingToDisk() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, mic, remote) = makeCoordinator(root: root)

        try await coordinator.startPrerollBuffer(app: app)
        await mic.push([1, 2, 3])
        await remote.push([4, 5, 6])
        await coordinator.discardPreroll()

        #expect(mic.stopCount == 1)
        #expect(remote.stopCount == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("recordings").path))
    }

    @Test func commitToDiskStartsFileWithPrerollSamples() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, mic, remote) = makeCoordinator(root: root)
        let session = SessionID(raw: "2026-08-16T14-00-00")

        try await coordinator.startPrerollBuffer(app: app)
        let prerollMic: [Float] = [0.1, 0.2, 0.3]
        let prerollRemote: [Float] = [0.4, 0.5]
        await mic.push(prerollMic)
        await remote.push(prerollRemote)

        try await coordinator.commitToDisk(session: session)

        let streamedMic: [Float] = [0.6, 0.7]
        await mic.push(streamedMic)

        let tracks = try await coordinator.stop()
        let micFile = try #require(tracks[.mic])
        let remoteFile = try #require(tracks[.remote])

        let micAudio = try AVAudioFile(forReading: micFile)
        #expect(micAudio.length == Int64(prerollMic.count + streamedMic.count))

        let remoteAudio = try AVAudioFile(forReading: remoteFile)
        #expect(remoteAudio.length == Int64(prerollRemote.count))
    }

    @Test func stopReturnsBothTracksAndStopsSources() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, mic, remote) = makeCoordinator(root: root)
        let session = SessionID(raw: "2026-08-16T15-00-00")

        try await coordinator.startPrerollBuffer(app: app)
        try await coordinator.commitToDisk(session: session)
        let tracks = try await coordinator.stop()

        #expect(Set(tracks.keys) == [.mic, .remote])
        #expect(mic.stopCount == 1)
        #expect(remote.stopCount == 1)
    }

    @Test func stopWithoutRecordingThrows() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, _, _) = makeCoordinator(root: root)

        await #expect(throws: AudioCaptureCoordinator.CoordinatorError.self) {
            try await coordinator.stop()
        }
    }

    @Test func pauseStopsWritingAndResumeContinues() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, mic, remote) = makeCoordinator(root: root)
        let session = SessionID(raw: "2026-08-16T16-00-00")

        try await coordinator.startPrerollBuffer(app: app)
        try await coordinator.commitToDisk(session: session)

        await coordinator.pause()
        await mic.push([9, 9, 9]) // must not be written while paused
        try await coordinator.resume()
        await mic.push([1, 1])

        let tracks = try await coordinator.stop()
        let micAudio = try AVAudioFile(forReading: try #require(tracks[.mic]))
        #expect(micAudio.length == 2)
        _ = remote
    }

    @Test func recentSamplesReturnsRequestedTail() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (coordinator, mic, _) = makeCoordinator(root: root)

        try await coordinator.startPrerollBuffer(app: app)
        await mic.push([1, 2, 3, 4, 5])

        let seconds = 4.0 / PrerollBuffer.sampleRate
        let recent = await coordinator.recentSamples(track: .mic, seconds: seconds)
        #expect(recent == [2, 3, 4, 5])
    }
}

// Device selection, the fix for two real meetings recorded as pure silence: the MacBook was
// closed at an external monitor, so the system default input was a microphone behind a shut lid.

@Test func preferredDeviceWinsOverEverythingElse() {
    let devices = ["MacBook Air-Mikrofon", "PC-LM1E", "Sebastians AirPods Pro"]
    #expect(pickName(preferred: ["AirPods", "PC-LM1E"], from: devices) == "Sebastians AirPods Pro")
    #expect(pickName(preferred: ["PC-LM1E"], from: devices) == "PC-LM1E")
}

@Test func unknownPreferenceFallsBackWithoutCrashing() {
    let devices = ["MacBook Air-Mikrofon"]
    #expect(pickName(preferred: ["Nicht Vorhanden"], from: devices) == "MacBook Air-Mikrofon")
    #expect(pickName(preferred: [], from: []) == nil)
}

/// Mirrors `MicCapture.selectDevice` for names alone: `AVCaptureDevice` cannot be constructed in
/// a test, but the ranking rule is the part worth pinning down.
private func pickName(preferred: [String], from devices: [String]) -> String? {
    for wanted in preferred {
        if let match = devices.first(where: { $0.localizedCaseInsensitiveContains(wanted) }) {
            return match
        }
    }
    return devices.first
}

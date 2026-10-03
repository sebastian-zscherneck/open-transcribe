import Foundation
import AVFoundation

/// Incrementally writes 16 kHz mono 16-bit PCM WAV to disk.
///
/// Backed by `AVAudioFile`, which already reserves a provisional header on open and patches
/// the header's length fields when the underlying file handle is released — exactly the
/// "reserve on open, patch on close" behaviour this needs, without a hand-rolled header.
/// That also guarantees the result reads back cleanly through `AVAudioFile` and FluidAudio's
/// converter, since both speak the same format.
public actor WAVWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let url: URL
    /// Byte offset of the `data` chunk's 4-byte size field. `AVAudioFile` reserves a padded
    /// header for alignment rather than the canonical fixed 44 bytes, so this is discovered once
    /// from the file it just created instead of being assumed.
    private let dataChunkOffset: Int?
    private var totalDataBytes: Int64 = 0

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.format = file.processingFormat
        self.file = file
        self.url = url
        self.dataChunkOffset = Self.locateDataChunkOffset(at: url)
    }

    /// Appends samples and immediately patches the RIFF/data chunk sizes on disk. No-op once
    /// `close()` has been called.
    ///
    /// `AVAudioFile` only patches those length fields when it is deallocated, so a process that
    /// gets killed mid-recording (a daemon restart, a crash) leaves a file whose header still
    /// claims zero length even though the audio data is sitting right there — unreadable by
    /// anything that trusts the header, including our own crash recovery. Patching after every
    /// write keeps the file honest at all times; the extra I/O is negligible next to writing the
    /// audio itself.
    public func write(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw WAVWriterError.bufferAllocationFailed
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)

        totalDataBytes += Int64(samples.count) * 2 // 16-bit mono
        patchHeader()
    }

    /// Releases the underlying file handle, which is what patches the WAV header's length
    /// fields. Safe to call more than once.
    public func close() {
        file = nil
    }

    private func patchHeader() {
        guard let dataChunkOffset else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let dataSize = UInt32(truncatingIfNeeded: totalDataBytes)
        let riffSize = UInt32(truncatingIfNeeded: Int64(dataChunkOffset) + 4 + totalDataBytes - 8)
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.littleEndianBytes(riffSize))
            try handle.seek(toOffset: UInt64(dataChunkOffset + 4))
            try handle.write(contentsOf: Self.littleEndianBytes(dataSize))
        } catch {
            // Best effort: a failed patch just leaves the previous, still-valid header in place.
        }
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Scans the freshly created file for the `data` chunk tag. Its offset never moves once the
    /// file is created, so this only needs to happen once.
    private static func locateDataChunkOffset(at url: URL) -> Int? {
        guard let header = try? Data(contentsOf: url) else { return nil }
        return header.range(of: Data("data".utf8))?.lowerBound
    }
}

public enum WAVWriterError: Error, Sendable, Equatable {
    case bufferAllocationFailed
}

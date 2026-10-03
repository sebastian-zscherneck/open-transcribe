import AVFoundation
import Foundation

/// Records the microphone straight to a file, purely to answer one question: is this machine's
/// microphone silent for this app, or is our sample-delivery path the thing losing the audio?
///
/// It deliberately uses `AVCaptureAudioFileOutput`, the same route a dictation app on this
/// machine records with successfully, instead of the `AVCaptureAudioDataOutput` callbacks the
/// real capture uses. Same process, same permission, different plumbing — so the result isolates
/// the plumbing.
public enum MicFileProbe {
    public struct Result: Sendable {
        public let peak: Float
        public let frames: Int
        public let note: String
    }

    public static func record(seconds: Int, preferredDevices: [String] = MicCapture.defaultPreferredDevices) async -> Result {
        guard let device = MicCapture.selectDevice(
            preferred: preferredDevices, from: MicCapture.availableDevices()
        ) else {
            return Result(peak: 0, frames: 0, note: "no input device")
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            return Result(peak: 0, frames: 0, note: "cannot open input")
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return Result(peak: 0, frames: 0, note: "session refused input or output")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ot-mic-probe-\(UUID().uuidString).caf")
        session.startRunning()
        guard session.isRunning else {
            return Result(peak: 0, frames: 0, note: "session did not start")
        }

        let delegate = ProbeDelegate()
        output.startRecording(to: url, outputFileType: .caf, recordingDelegate: delegate)
        try? await Task.sleep(for: .seconds(seconds))
        output.stopRecording()
        // Give the file output a moment to flush and close before reading it back.
        try? await Task.sleep(for: .milliseconds(700))
        session.stopRunning()

        defer { try? FileManager.default.removeItem(at: url) }
        return measure(url)
    }

    private static func measure(_ url: URL) -> Result {
        guard let file = try? AVAudioFile(forReading: url) else {
            return Result(peak: 0, frames: 0, note: "file unreadable")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData
        else {
            return Result(peak: 0, frames: Int(file.length), note: "no readable frames")
        }

        var peak: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[0][frame]))
        }
        return Result(peak: peak, frames: Int(buffer.frameLength), note: "ok")
    }
}

private final class ProbeDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {}
}

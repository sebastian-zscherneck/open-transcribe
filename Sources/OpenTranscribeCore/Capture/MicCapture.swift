import AVFoundation
import Foundation

public enum MicCaptureError: Error, Sendable, Equatable {
    /// The user has denied microphone access.
    case permissionDenied
    /// Access has not been decided yet; the system prompt was just raised.
    case permissionPending
    case noInputDevice
    case sessionUnavailable
    case alreadyRunning
}

/// Captures the system's default input device as 16 kHz mono Float32.
///
/// Built on `AVCaptureSession` rather than `AVAudioEngine` on purpose. The engine variant taps
/// fine — buffers arrive at the expected rate, permission granted, no error anywhere — but every
/// sample came back bit-exact zero on this machine, measured across three independent paths.
/// The capture-session path demonstrably records here, and proven beats elegant for the one
/// component the whole tool depends on.
///
/// The device is never selected or switched explicitly: `AVCaptureDevice.default(for: .audio)`
/// follows whatever the system considers the default input.
public final class MicCapture: NSObject, CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var onSamples: (@Sendable ([Float]) async -> Void)?
    private let queue = DispatchQueue(label: "com.sebastianzscherneck.opentranscribe.mic")
    private let preferredDevices: [String]

    /// `preferredDevices` are matched against device names, best first. The default order exists
    /// because a MacBook closed on a desk still reports its built-in microphone as the system
    /// default input, and that microphone delivers digital silence — which is exactly how this
    /// tool recorded two real meetings of nothing.
    public init(preferredDevices: [String] = MicCapture.defaultPreferredDevices) {
        self.preferredDevices = preferredDevices
        super.init()
    }

    public static let defaultPreferredDevices = ["AirPods", "PC-LM1E"]

    /// Every input the system offers, best candidate first.
    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// Picks the input to record from.
    ///
    /// Order: an explicitly preferred device, then anything that is not the built-in microphone,
    /// then the system default as a last resort. External beats built-in on purpose — in
    /// clamshell mode the built-in one is unusable, and no API reports that, it just goes silent.
    static func selectDevice(preferred: [String], from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        for wanted in preferred {
            if let match = devices.first(where: {
                $0.localizedName.localizedCaseInsensitiveContains(wanted) || $0.uniqueID == wanted
            }) {
                return match
            }
        }
        if let external = devices.first(where: { $0.deviceType == .external }) { return external }
        return devices.first ?? AVCaptureDevice.default(for: .audio)
    }

    /// Name of the device this capture is bound to, for diagnostics.
    public private(set) var activeDeviceName: String = "-"

    public func start(onSamples: @escaping @Sendable ([Float]) async -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { throw MicCaptureError.alreadyRunning }

        try requestMicPermissionIfNeeded()

        guard let device = Self.selectDevice(preferred: preferredDevices, from: Self.availableDevices()) else {
            throw MicCaptureError.noInputDevice
        }
        activeDeviceName = device.localizedName
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // The capture session resamples for us, so the tap already delivers what the models want.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicCaptureError.sessionUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        self.onSamples = onSamples
        output.setSampleBufferDelegate(self, queue: queue)

        session.startRunning()
        guard session.isRunning else {
            self.onSamples = nil
            throw MicCaptureError.sessionUnavailable
        }
        self.session = session
    }

    public func stop() {
        lock.lock()
        let running = session
        session = nil
        onSamples = nil
        lock.unlock()
        running?.stopRunning()
    }

    /// Never blocks waiting for the user.
    ///
    /// The prompt needs a run loop to appear, so parking this thread on a semaphore until the
    /// answer arrives deadlocks whoever called us. Instead the request is kicked off and
    /// `permissionPending` is thrown, which surfaces as a visible error the user can act on.
    private func requestMicPermissionIfNeeded() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw MicCaptureError.permissionPending
        case .denied, .restricted:
            throw MicCaptureError.permissionDenied
        @unknown default:
            throw MicCaptureError.permissionDenied
        }
    }
}

extension MicCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = Self.floatSamples(from: sampleBuffer) else { return }
        lock.lock()
        let sink = onSamples
        lock.unlock()
        guard let sink else { return }
        // This is a capture callback: hand the samples off and return immediately.
        Task { await sink(samples) }
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return nil }

        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        return pointer.withMemoryRebound(to: Float.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
    }
}

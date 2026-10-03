import Foundation

/// Fixed-capacity ring buffer for 16 kHz mono Float32 samples.
///
/// Pure and synchronous, no audio frameworks involved, so it is trivially unit-testable.
/// Used to hold the "did a meeting just start" preroll window in memory before a recording
/// is (or isn't) promoted to disk.
public struct PrerollBuffer: Sendable {
    public static let sampleRate: Double = 16_000

    public let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0

    public init(seconds: TimeInterval = 90) {
        self.capacity = max(1, Int(seconds * Self.sampleRate))
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Number of samples currently held.
    public var storedCount: Int { count }

    /// Appends samples in order. Once capacity is exceeded, the oldest samples are
    /// overwritten first.
    public mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Only the tail can possibly survive if a single chunk is larger than capacity.
        let toWrite = samples.count > capacity ? Array(samples.suffix(capacity)) : samples
        for sample in toWrite {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    /// Returns the buffered samples in chronological order without clearing the buffer.
    public func peek() -> [Float] {
        guard count > 0 else { return [] }
        let start = (writeIndex - count + capacity) % capacity
        if start + count <= capacity {
            return Array(storage[start..<(start + count)])
        }
        let head = Array(storage[start..<capacity])
        let tail = Array(storage[0..<(count - head.count)])
        return head + tail
    }

    /// Returns the buffered samples in chronological order and empties the buffer.
    public mutating func drain() -> [Float] {
        let result = peek()
        writeIndex = 0
        count = 0
        return result
    }
}

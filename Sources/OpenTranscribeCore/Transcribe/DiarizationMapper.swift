import Foundation

/// Pure word-to-speaker assignment. No FluidAudio types so this stays testable without models.
public enum DiarizationMapper {

    /// One recognised token with its time span, independent of any ASR framework type.
    public struct TimedToken: Sendable, Equatable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One diarizer cluster span, independent of any diarization framework type.
    public struct SpeakerSpan: Sendable, Equatable {
        public let label: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(label: String, start: TimeInterval, end: TimeInterval) {
            self.label = label
            self.start = start
            self.end = end
        }
    }

    /// One grouped run of consecutive same-speaker tokens.
    public struct Assignment: Sendable, Equatable {
        public let speaker: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String

        public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Assigns each token to the speaker span with the greatest time overlap, then groups
    /// consecutive tokens of the same speaker into segments. A token with zero overlap against
    /// every span (e.g. diarizer silence gap) is dropped rather than guessed.
    ///
    /// - Parameters:
    ///   - tokens: Word/token timings from the ASR pass, in chronological order.
    ///   - spans: Diarizer cluster spans, in any order.
    ///   - maxPauseWithinSegment: Consecutive same-speaker tokens separated by more than this gap
    ///     start a new segment instead of being merged into one.
    public static func assign(
        tokens: [TimedToken],
        spans: [SpeakerSpan],
        maxPauseWithinSegment: TimeInterval = 1.5
    ) -> [Assignment] {
        var segments: [Assignment] = []
        var currentSpeaker: String?
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var currentWords: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, !currentWords.isEmpty else { return }
            segments.append(
                Assignment(speaker: speaker, start: currentStart, end: currentEnd, text: currentWords.joined(separator: " "))
            )
            currentWords = []
        }

        for token in tokens {
            guard let speaker = bestSpeaker(for: token, in: spans) else { continue }

            let isContinuation =
                speaker == currentSpeaker && (token.start - currentEnd) <= maxPauseWithinSegment
            if !isContinuation {
                flush()
                currentSpeaker = speaker
                currentStart = token.start
            }
            currentEnd = token.end
            currentWords.append(token.text)
        }
        flush()

        return segments
    }

    /// Speaker of the span with the largest overlap against `token`. `nil` when no span overlaps at all.
    private static func bestSpeaker(for token: TimedToken, in spans: [SpeakerSpan]) -> String? {
        var bestLabel: String?
        var bestOverlap: TimeInterval = 0

        for span in spans {
            let overlap = max(0, min(token.end, span.end) - max(token.start, span.start))
            guard overlap > 0 else { continue }
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestLabel = span.label
            }
        }
        return bestLabel
    }
}

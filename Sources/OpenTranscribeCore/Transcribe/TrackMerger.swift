import Foundation

/// Pure chronological merge of two already-transcribed tracks into one timeline.
public enum TrackMerger {

    /// Merges `mic` and `remote` segments by start time. Ties keep mic before remote (stable),
    /// matching the source order of `[mic, remote]` in a stable sort.
    ///
    /// When `collapseConsecutiveSameSpeaker` is true, directly adjacent segments in the merged
    /// result that share a speaker are joined into one (text concatenated with a space, end time
    /// extended). Segments are only ever joined if they are already neighbours after sorting —
    /// this never reorders anything.
    public static func merge(
        mic: [TranscriptSegment],
        remote: [TranscriptSegment],
        collapseConsecutiveSameSpeaker: Bool = false
    ) -> [TranscriptSegment] {
        // Tag with source index so the stable sort can break ties mic-before-remote.
        let tagged: [(segment: TranscriptSegment, order: Int)] =
            mic.enumerated().map { ($0.element, $0.offset) }
            + remote.enumerated().map { ($0.element, mic.count + $0.offset) }

        let sorted =
            tagged
            .sorted { lhs, rhs in
                if lhs.segment.start != rhs.segment.start {
                    return lhs.segment.start < rhs.segment.start
                }
                // Equal start: mic (track == .mic) sorts first.
                if lhs.segment.track != rhs.segment.track {
                    return lhs.segment.track == .mic
                }
                return lhs.order < rhs.order
            }
            .map(\.segment)

        guard collapseConsecutiveSameSpeaker else { return sorted }

        var result: [TranscriptSegment] = []
        for segment in sorted {
            if let last = result.last, last.speaker == segment.speaker {
                let joined = TranscriptSegment(
                    start: last.start,
                    end: max(last.end, segment.end),
                    track: last.track,
                    speaker: last.speaker,
                    text: last.text + " " + segment.text
                )
                result[result.count - 1] = joined
            } else {
                result.append(segment)
            }
        }
        return result
    }
}

import Foundation

/// Turns raw grouped speech into readable paragraphs.
///
/// The grouping that comes out of word-to-speaker mapping splits on pauses alone. On real
/// material that produced 838-character monoliths on one end and sentences cut mid-clause on the
/// other: 37 of 57 segments of a real meeting ended without any sentence punctuation.
public enum SegmentShaper {
    /// A segment longer than this is split at the next sentence boundary.
    public static let maxCharacters = 320
    /// A fragment is glued to the following segment of the same speaker if the gap is short.
    public static let maxMergeGap: TimeInterval = 8

    public static func shape(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        split(merge(segments))
    }

    /// Glues a segment that stops mid-sentence onto the next one of the same speaker.
    static func merge(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard let previous = result.last,
                  previous.speaker == segment.speaker,
                  previous.track == segment.track,
                  !endsSentence(previous.text),
                  segment.start - previous.end <= maxMergeGap,
                  previous.text.count + segment.text.count <= maxCharacters * 2
            else {
                result.append(segment)
                continue
            }
            result[result.count - 1] = TranscriptSegment(
                start: previous.start,
                end: segment.end,
                track: previous.track,
                speaker: previous.speaker,
                text: previous.text + " " + segment.text
            )
        }
        return result
    }

    /// Splits an over-long segment at sentence boundaries, interpolating timestamps by character
    /// position — the word timings are gone by this point, and a proportional estimate is close
    /// enough for a reading aid.
    static func split(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard segment.text.count > maxCharacters else {
                result.append(segment)
                continue
            }
            let chunks = sentenceChunks(segment.text, limit: maxCharacters)
            guard chunks.count > 1 else {
                result.append(segment)
                continue
            }

            let total = Double(segment.text.count)
            var consumed = 0.0
            let duration = max(0, segment.end - segment.start)
            for chunk in chunks {
                let startFraction = consumed / total
                consumed += Double(chunk.count)
                let endFraction = consumed / total
                result.append(TranscriptSegment(
                    start: segment.start + duration * startFraction,
                    end: segment.start + duration * endFraction,
                    track: segment.track,
                    speaker: segment.speaker,
                    text: chunk
                ))
            }
        }
        return result
    }

    /// Groups sentences into chunks that stay under `limit` where the text allows it.
    static func sentenceChunks(_ text: String, limit: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        guard sentences.count > 1 else { return [text] }

        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + sentence.count + 1 <= limit {
                buffer += " " + sentence
            } else {
                chunks.append(buffer)
                buffer = sentence
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return true }
        return last == "." || last == "!" || last == "?"
    }
}

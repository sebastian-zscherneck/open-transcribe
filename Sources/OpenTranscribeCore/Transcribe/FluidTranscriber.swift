import FluidAudio
import Foundation

/// `OfflineDiarizerManager` documents its own internal synchronization (Core ML models are
/// written only once during initialization, then read-only) but predates Swift 6 Sendable
/// checking, so it isn't marked `Sendable` upstream. Asserting that documented contract here
/// lets a single actor-owned instance be awaited without spurious data-race diagnostics.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

/// Errors specific to the transcription pipeline. Always thrown, never a silent empty result,
/// except where the spec calls for graceful degradation (see `finalPass`).
public enum FluidTranscriberError: Error, LocalizedError {
    case notPrepared
    case modelDownloadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "FluidTranscriber.prepare() must succeed before transcribing."
        case .modelDownloadFailed(let underlying):
            return "Failed to download or load transcription models: \(underlying.localizedDescription)"
        }
    }
}

/// `Transcribing` backed by FluidAudio's Parakeet ASR, Silero VAD, and offline pyannote-style
/// diarization. Model loading is idempotent (`prepare()` is a no-op once models are hot) and this
/// type is an actor so it's safe to drive from multiple callers.
public actor FluidTranscriber: Transcribing, SpeakerLearning {
    private var asrManager: AsrManager?
    private var decoderLayers: Int = 2
    private var vadManager: VadManager?
    private let offlineDiarizer = OfflineDiarizerManager()
    private var isPrepared = false

    /// Segments within this many seconds of silence are still one utterance; a longer gap starts
    /// a new segment. Shared across mic (single speaker) and remote (diarized) grouping.
    private let maxPauseWithinSegment: TimeInterval = 1.5

    /// Known voices. Optional so the transcriber stays usable (and testable) without a store.
    private let profiles: SpeakerProfiling?
    /// Voice of each cluster of the most recent final pass, keyed by the label used in the
    /// transcript. Lets a name confirmed afterwards be folded back into the right profile.
    private var lastClusterVoices: [String: [Float]] = [:]
    /// Profile match per cluster label of the most recent final pass, handed to the transcript
    /// as suggestions.
    private var lastSuggestions: [String: String] = [:]

    public init(profiles: SpeakerProfiling? = nil) {
        self.profiles = profiles
    }

    /// Remembers the voice behind a label under the name the user just confirmed.
    public func learn(label: String, as name: String) async {
        guard let profiles, let embedding = lastClusterVoices[label] else { return }
        try? await profiles.remember(name: name, embedding: embedding)
        lastClusterVoices[name] = embedding
    }

    public func prepare() async throws {
        guard !isPrepared else { return }

        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: .v3)
        } catch {
            throw FluidTranscriberError.modelDownloadFailed(error)
        }
        let manager = AsrManager(models: models)
        self.asrManager = manager
        self.decoderLayers = await manager.decoderLayerCount

        self.vadManager = try await VadManager()

        try await offlineDiarizer.prepareModels()

        isPrepared = true
    }

    // MARK: - Live preview

    public func transcribeLiveChunk(_ samples: [Float], track: Track, offset: TimeInterval) async throws -> [LiveLine] {
        guard isPrepared, let asrManager, let vadManager else { throw FluidTranscriberError.notPrepared }
        guard !samples.isEmpty else { return [] }

        // VAD-gate: skip the (expensive) ASR pass entirely on silent chunks.
        let vadResults = try await vadManager.process(samples)
        guard vadResults.contains(where: \.isVoiceActive) else { return [] }

        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await asrManager.transcribe(samples, decoderState: &state)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let speaker = track == .mic ? "Du" : "Andere"
        return [LiveLine(at: offset, speaker: speaker, text: text)]
    }

    // MARK: - Final pass

    public func finalPass(tracks: [Track: URL], context: FinalPassContext) async throws -> Transcript {
        guard isPrepared, let asrManager else { throw FluidTranscriberError.notPrepared }

        let micSegments = try await transcribeMic(tracks[.mic], asrManager: asrManager, ownerName: context.ownerName)
        let remoteSegments = try await transcribeRemote(tracks[.remote], asrManager: asrManager)

        // Shape each track on its own: merging fragments across speakers would be wrong.
        let merged = TrackMerger.merge(
            mic: SegmentShaper.shape(micSegments),
            remote: SegmentShaper.shape(remoteSegments)
        )
        let duration = merged.map(\.end).max() ?? 0

        return Transcript(
            session: context.session,
            recordedAt: context.recordedAt,
            duration: duration,
            appName: context.appName,
            calendarTitle: context.calendar?.title,
            segments: merged,
            speakerSuggestions: lastSuggestions
        )
    }

    /// Whole mic track, single known speaker. Still split into segments on pause so the
    /// chronological merge with the remote track produces a readable, interleaved transcript.
    private func transcribeMic(_ url: URL?, asrManager: AsrManager, ownerName: String) async throws -> [TranscriptSegment] {
        guard let url else { return [] }

        let result = try await transcribeTrack(url, asrManager: asrManager)
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else { return [] }

        let words = buildWordTimings(from: tokenTimings)
        let tokens = words.map { DiarizationMapper.TimedToken(text: $0.word, start: $0.startTime, end: $0.endTime) }
        let fullSpan = Self.ownerSpan(covering: tokens, label: ownerName)

        let assignments = DiarizationMapper.assign(tokens: tokens, spans: [fullSpan], maxPauseWithinSegment: maxPauseWithinSegment)
        return assignments.map {
            TranscriptSegment(
                start: $0.start, end: $0.end, track: .mic, speaker: $0.speaker,
                text: RepetitionCleaner.clean($0.text)
            )
        }
    }

    /// One span covering every token of the microphone track.
    ///
    /// Derived from the tokens instead of `ASRResult.duration` on purpose: for longer recordings
    /// the engine reports `duration == 0` while the token timings are perfectly fine, and a span
    /// of zero length silently dropped every word of the owner's track. A 32 minute meeting came
    /// out with the other side only, and nothing anywhere reported an error.
    static func ownerSpan(covering tokens: [DiarizationMapper.TimedToken], label: String) -> DiarizationMapper.SpeakerSpan {
        let start = min(0, tokens.first?.start ?? 0)
        let end = (tokens.last?.end ?? 0) + 1
        return DiarizationMapper.SpeakerSpan(label: label, start: start, end: end)
    }

    /// Whole remote track, diarized into clusters and word-mapped to them. An empty or missing
    /// remote track (self-talk) yields an empty list rather than failing.
    private func transcribeRemote(_ url: URL?, asrManager: AsrManager) async throws -> [TranscriptSegment] {
        guard let url else { return [] }

        // Sequential rather than `async let`: OfflineDiarizerManager isn't Sendable, and both
        // passes already run at full throughput internally (Core ML + ANE), so nothing is lost.
        let result = try await transcribeTrack(url, asrManager: asrManager)
        let diarization = try await offlineDiarizer.process(url)

        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else { return [] }
        guard !diarization.segments.isEmpty else { return [] }

        var speakerLabels = Self.assignSpeakerLabels(diarization.segments)
        let voices = Self.clusterVoices(diarization.segments)

        // A voice that resembles a stored profile becomes a suggestion for the naming question.
        // Never the name itself: a stranger has measured 0.26 from a profile, closer than most
        // people are to their own, so the user has to confirm before a name goes into the wiki.
        lastClusterVoices = [:]
        lastSuggestions = [:]
        for (clusterId, label) in speakerLabels {
            guard let voice = voices[clusterId] else { continue }
            lastClusterVoices[label] = voice
            if let match = await profiles?.match(embedding: voice) {
                lastSuggestions[label] = match.name
            }
        }

        let spans = diarization.segments.map {
            DiarizationMapper.SpeakerSpan(
                label: speakerLabels[$0.speakerId] ?? $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }

        let words = buildWordTimings(from: tokenTimings)
        let tokens = words.map { DiarizationMapper.TimedToken(text: $0.word, start: $0.startTime, end: $0.endTime) }

        let assignments = DiarizationMapper.assign(tokens: tokens, spans: spans, maxPauseWithinSegment: maxPauseWithinSegment)
        return assignments.map {
            TranscriptSegment(
                start: $0.start, end: $0.end, track: .remote, speaker: $0.speaker,
                text: RepetitionCleaner.clean($0.text)
            )
        }
    }

    private func transcribeTrack(_ url: URL, asrManager: AsrManager) async throws -> ASRResult {
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        return try await asrManager.transcribe(url, decoderState: &state)
    }

    /// One representative voice per cluster: the mean of its segment embeddings weighted by how
    /// long each segment lasted, so a two-second interjection cannot skew a ten-minute speaker.
    static func clusterVoices(_ segments: [TimedSpeakerSegment]) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var weights: [String: Float] = [:]

        for segment in segments where !segment.embedding.isEmpty {
            let weight = max(segment.durationSeconds, 0.01)
            if var sum = sums[segment.speakerId], sum.count == segment.embedding.count {
                for index in sum.indices { sum[index] += segment.embedding[index] * weight }
                sums[segment.speakerId] = sum
            } else if sums[segment.speakerId] == nil {
                sums[segment.speakerId] = segment.embedding.map { $0 * weight }
            } else {
                continue
            }
            weights[segment.speakerId, default: 0] += weight
        }

        return sums.reduce(into: [:]) { result, entry in
            guard let weight = weights[entry.key], weight > 0 else { return }
            result[entry.key] = entry.value.map { $0 / weight }
        }
    }

    /// Maps raw diarizer cluster ids to "Speaker A", "Speaker B", ... in order of first
    /// appearance so labels read naturally in a chronological transcript.
    private static func assignSpeakerLabels(_ segments: [TimedSpeakerSegment]) -> [String: String] {
        let orderedIds = segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map(\.speakerId)

        var labels: [String: String] = [:]
        var nextLetter: UInt8 = UInt8(ascii: "A")
        for id in orderedIds where labels[id] == nil {
            labels[id] = "Speaker \(Character(UnicodeScalar(nextLetter)))"
            nextLetter += 1
        }
        return labels
    }
}

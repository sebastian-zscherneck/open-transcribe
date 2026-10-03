import Foundation
import Testing

@testable import OpenTranscribeCore

// MARK: - DiarizationMapper

@Test func diarizationMapperAssignsClearOverlap() {
    let tokens = [
        DiarizationMapper.TimedToken(text: "hallo", start: 0.0, end: 0.5),
        DiarizationMapper.TimedToken(text: "welt", start: 0.5, end: 1.0),
    ]
    let spans = [
        DiarizationMapper.SpeakerSpan(label: "Speaker A", start: 0.0, end: 1.0)
    ]

    let result = DiarizationMapper.assign(tokens: tokens, spans: spans)

    #expect(result.count == 1)
    #expect(result[0].speaker == "Speaker A")
    #expect(result[0].text == "hallo welt")
    #expect(result[0].start == 0.0)
    #expect(result[0].end == 1.0)
}

@Test func diarizationMapperPicksLargerOverlapAtSpeakerBoundary() {
    // Token spans [0.9, 1.3]. Speaker A owns [0,1] (0.1s overlap), Speaker B owns [1,2] (0.3s overlap).
    let tokens = [
        DiarizationMapper.TimedToken(text: "wort", start: 0.9, end: 1.3)
    ]
    let spans = [
        DiarizationMapper.SpeakerSpan(label: "Speaker A", start: 0.0, end: 1.0),
        DiarizationMapper.SpeakerSpan(label: "Speaker B", start: 1.0, end: 2.0),
    ]

    let result = DiarizationMapper.assign(tokens: tokens, spans: spans)

    #expect(result.count == 1)
    #expect(result[0].speaker == "Speaker B")
}

@Test func diarizationMapperDropsTokenWithoutOverlap() {
    let tokens = [
        DiarizationMapper.TimedToken(text: "vorher", start: 0.0, end: 0.5),
        DiarizationMapper.TimedToken(text: "danach", start: 5.0, end: 5.5),
    ]
    let spans = [
        DiarizationMapper.SpeakerSpan(label: "Speaker A", start: 0.0, end: 1.0)
    ]

    let result = DiarizationMapper.assign(tokens: tokens, spans: spans)

    #expect(result.count == 1)
    #expect(result[0].text == "vorher")
}

@Test func diarizationMapperSplitsOnLongPause() {
    let tokens = [
        DiarizationMapper.TimedToken(text: "erst", start: 0.0, end: 0.5),
        // 2s gap, longer than the 1.5s default max pause.
        DiarizationMapper.TimedToken(text: "spaeter", start: 2.5, end: 3.0),
    ]
    let spans = [
        DiarizationMapper.SpeakerSpan(label: "Speaker A", start: 0.0, end: 3.0)
    ]

    let result = DiarizationMapper.assign(tokens: tokens, spans: spans, maxPauseWithinSegment: 1.5)

    #expect(result.count == 2)
    #expect(result[0].text == "erst")
    #expect(result[1].text == "spaeter")
}

@Test func diarizationMapperKeepsShortPauseInOneSegment() {
    let tokens = [
        DiarizationMapper.TimedToken(text: "erst", start: 0.0, end: 0.5),
        DiarizationMapper.TimedToken(text: "spaeter", start: 1.0, end: 1.5),
    ]
    let spans = [
        DiarizationMapper.SpeakerSpan(label: "Speaker A", start: 0.0, end: 2.0)
    ]

    let result = DiarizationMapper.assign(tokens: tokens, spans: spans, maxPauseWithinSegment: 1.5)

    #expect(result.count == 1)
    #expect(result[0].text == "erst spaeter")
}

// MARK: - TrackMerger

@Test func trackMergerOrdersChronologically() {
    let mic = [seg(start: 2, end: 3, track: .mic, speaker: "Sebastian", text: "b")]
    let remote = [
        seg(start: 0, end: 1, track: .remote, speaker: "Speaker A", text: "a"),
        seg(start: 4, end: 5, track: .remote, speaker: "Speaker A", text: "c"),
    ]

    let merged = TrackMerger.merge(mic: mic, remote: remote)

    #expect(merged.map(\.text) == ["a", "b", "c"])
}

@Test func trackMergerBreaksTiesMicFirst() {
    let mic = [seg(start: 1, end: 2, track: .mic, speaker: "Sebastian", text: "mic")]
    let remote = [seg(start: 1, end: 2, track: .remote, speaker: "Speaker A", text: "remote")]

    let merged = TrackMerger.merge(mic: mic, remote: remote)

    #expect(merged.map(\.text) == ["mic", "remote"])
}

@Test func trackMergerCollapsesConsecutiveSameSpeaker() {
    let mic = [
        seg(start: 0, end: 1, track: .mic, speaker: "Sebastian", text: "eins"),
        seg(start: 1, end: 2, track: .mic, speaker: "Sebastian", text: "zwei"),
    ]

    let merged = TrackMerger.merge(mic: mic, remote: [], collapseConsecutiveSameSpeaker: true)

    #expect(merged.count == 1)
    #expect(merged[0].text == "eins zwei")
    #expect(merged[0].end == 2)
}

@Test func trackMergerDoesNotCollapseWhenDisabled() {
    let mic = [
        seg(start: 0, end: 1, track: .mic, speaker: "Sebastian", text: "eins"),
        seg(start: 1, end: 2, track: .mic, speaker: "Sebastian", text: "zwei"),
    ]

    let merged = TrackMerger.merge(mic: mic, remote: [])

    #expect(merged.count == 2)
}

private func seg(start: TimeInterval, end: TimeInterval, track: Track, speaker: String, text: String) -> TranscriptSegment {
    TranscriptSegment(start: start, end: end, track: track, speaker: speaker, text: text)
}

// MARK: - ProfileStore

private func tempPaths() -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return Paths(root: root, wikiRaw: root.appendingPathComponent("wiki"))
}

@Test func profileStoreMatchesAboveThreshold() async throws {
    let store = ProfileStore(paths: tempPaths())
    let embedding: [Float] = [1, 0, 0, 0]

    try await store.remember(name: "Sebastian", embedding: embedding)
    let match = await store.match(embedding: embedding)

    #expect(match?.name == "Sebastian")
    #expect(match?.distance == 0)
}

@Test func profileStoreRejectsAmbiguousMatchWithoutMargin() async throws {
    // Two people whose profiles are nearly the same distance from the probe: the store must
    // not pick one on a hair's breadth. That is exactly how a stranger got labelled "Alex".
    let store = ProfileStore(paths: tempPaths(), threshold: 0.6, margin: 0.1)
    try await store.remember(name: "Alex", embedding: [1, 0.30, 0, 0])
    try await store.remember(name: "Jonas", embedding: [1, 0, 0.30, 0])

    let match = await store.match(embedding: [1, 0.05, 0, 0])

    #expect(match == nil)
}

@Test func profileStoreMatchesWhenRunnerUpIsClearlyFurther() async throws {
    let store = ProfileStore(paths: tempPaths(), threshold: 0.6, margin: 0.1)
    try await store.remember(name: "Alex", embedding: [1, 0, 0, 0])
    try await store.remember(name: "Jonas", embedding: [0, 1, 0, 0])

    let match = await store.match(embedding: [1, 0.1, 0, 0])

    #expect(match?.name == "Alex")
}

@Test func profileStoreLogsEveryMatchAttempt() async throws {
    let paths = tempPaths()
    let store = ProfileStore(paths: paths)
    try await store.remember(name: "Alex", embedding: [1, 0, 0, 0])

    _ = await store.match(embedding: [1, 0, 0, 0])
    _ = await store.match(embedding: [0, 1, 0, 0])

    let log = try String(contentsOf: paths.logsDir.appendingPathComponent("speakers.log"), encoding: .utf8)
    let lines = log.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("Alex 0.00"))
    #expect(lines[0].contains("-> Alex"))
    #expect(lines[1].contains("Alex 1.00"))
    #expect(lines[1].contains("-> unknown"))
}

@Test func profileStoreNoMatchBelowThreshold() async throws {
    let store = ProfileStore(paths: tempPaths(), threshold: 0.1)
    try await store.remember(name: "Sebastian", embedding: [1, 0, 0, 0])

    // Orthogonal vector: cosine distance == 1, far above the 0.1 threshold.
    let match = await store.match(embedding: [0, 1, 0, 0])

    #expect(match == nil)
}

@Test func profileStoreAveragingShiftsProfileTowardNewSamples() async throws {
    let store = ProfileStore(paths: tempPaths(), threshold: 0.99)
    try await store.remember(name: "Sebastian", embedding: [1, 0, 0, 0])
    try await store.remember(name: "Sebastian", embedding: [0, 1, 0, 0])

    // Averaged profile now sits between the two axes; a pure [0,1,0,0] probe should be closer
    // to it than to the original [1,0,0,0] would have been.
    let names = await store.knownNames()
    #expect(names == ["Sebastian"])
}

@Test func profileStorePersistsAcrossInstances() async throws {
    let paths = tempPaths()
    let first = ProfileStore(paths: paths)
    try await first.remember(name: "Sebastian", embedding: [1, 0, 0, 0])

    let second = ProfileStore(paths: paths)
    let match = await second.match(embedding: [1, 0, 0, 0])
    let names = await second.knownNames()

    #expect(match?.name == "Sebastian")
    #expect(names == ["Sebastian"])
}

// The owner's track lost every word of a 32 minute meeting because the span it was matched
// against came from ASRResult.duration, which the engine reported as 0 for long recordings.

@Test func ownerSpanCoversEveryTokenRegardlessOfReportedDuration() {
    let tokens = [
        DiarizationMapper.TimedToken(text: "Moin", start: 0.4, end: 0.9),
        DiarizationMapper.TimedToken(text: "Alex", start: 1.0, end: 1.6),
        DiarizationMapper.TimedToken(text: "Schluss", start: 1_900.0, end: 1_900.8),
    ]
    let span = FluidTranscriber.ownerSpan(covering: tokens, label: "Sebastian")
    #expect(span.label == "Sebastian")
    #expect(span.start <= 0.4)
    #expect(span.end >= 1_900.8)

    // And the mapper actually keeps the words when handed that span.
    let assignments = DiarizationMapper.assign(tokens: tokens, spans: [span])
    #expect(assignments.count == 2)
    #expect(assignments.allSatisfy { $0.speaker == "Sebastian" })
}

@Test func ownerSpanSurvivesAnEmptyTrack() {
    let span = FluidTranscriber.ownerSpan(covering: [], label: "Sebastian")
    #expect(DiarizationMapper.assign(tokens: [], spans: [span]).isEmpty)
}

// Segment shaping. Real material: 37 of 57 segments ended mid-sentence, the longest ran 838
// characters, which reads like a wall and cuts clauses in half.

@Test func fragmentIsGluedToTheFollowingSegmentOfTheSameSpeaker() {
    let segments = [
        TranscriptSegment(start: 0, end: 4, track: .mic, speaker: "Sebastian", text: "Ich wollte den Stand durchgehen,"),
        TranscriptSegment(start: 5, end: 9, track: .mic, speaker: "Sebastian", text: "weil die Zahlen jetzt nachts laufen."),
    ]
    let shaped = SegmentShaper.shape(segments)
    #expect(shaped.count == 1)
    #expect(shaped[0].text == "Ich wollte den Stand durchgehen, weil die Zahlen jetzt nachts laufen.")
    #expect(shaped[0].start == 0)
    #expect(shaped[0].end == 9)
}

@Test func differentSpeakersAreNeverGluedTogether() {
    let segments = [
        TranscriptSegment(start: 0, end: 4, track: .mic, speaker: "Sebastian", text: "Und dann dachte ich,"),
        TranscriptSegment(start: 5, end: 9, track: .remote, speaker: "Jonas", text: "ja das passt so."),
    ]
    #expect(SegmentShaper.shape(segments).count == 2)
}

@Test func anOverlongSegmentIsSplitAtSentenceBoundaries() {
    let sentence = "Das ist ein vollständiger Satz über Bestände und Werbekosten im Dashboard. "
    let long = String(repeating: sentence, count: 6)
    let segments = [TranscriptSegment(start: 0, end: 60, track: .remote, speaker: "Jonas", text: long)]

    let shaped = SegmentShaper.shape(segments)
    #expect(shaped.count > 1)
    #expect(shaped.allSatisfy { $0.text.count <= SegmentShaper.maxCharacters + 80 })
    #expect(shaped.allSatisfy { $0.text.hasSuffix(".") })
    // Timestamps stay inside the original span and keep their order.
    #expect(shaped.first?.start == 0)
    #expect((shaped.last?.end ?? 0) <= 60.001)
    #expect(zip(shaped, shaped.dropFirst()).allSatisfy { $0.start <= $1.start })
}

@Test func aSegmentWithoutSentenceBoundariesIsNotChopped() {
    let text = String(repeating: "und dann noch ", count: 40)
    let segments = [TranscriptSegment(start: 0, end: 30, track: .mic, speaker: "Sebastian", text: text)]
    #expect(SegmentShaper.shape(segments).count == 1)
}


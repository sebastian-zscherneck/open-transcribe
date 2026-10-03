import Foundation
import Testing
@testable import OpenTranscribeCore

// MARK: - Slug

@Test func slugNormalizesUmlautsAndSpaces() {
    #expect(Slug.normalize("Mühlenbäcker Wöchentlich") == "muehlenbaecker-woechentlich")
}

@Test func slugTransliteratesEszett() {
    #expect(Slug.normalize("Großes Meeting") == "grosses-meeting")
}

@Test func slugCollapsesRepeatedSeparators() {
    #expect(Slug.normalize("Foo   Bar--Baz!!") == "foo-bar-baz")
}

@Test func slugTrimsLeadingAndTrailingSeparators() {
    #expect(Slug.normalize("  -Weekly Sync-  ") == "weekly-sync")
}

@Test func slugTruncatesWithoutCuttingAWordInHalf() {
    let long = "alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo"
    let result = Slug.normalize(long)
    #expect(result != nil)
    #expect((result?.count ?? 0) <= 40)
    #expect(result?.hasSuffix("-") == false)

    let sourceWords = Set(long.lowercased().split(separator: " ").map(String.init))
    for fragment in (result ?? "").split(separator: "-") {
        #expect(sourceWords.contains(String(fragment)))
    }
}

@Test func slugRejectsInputThatNormalizesToNothingUsable() {
    #expect(Slug.normalize("ab") == nil)
    #expect(Slug.normalize("") == nil)
    #expect(Slug.normalize("!!!") == nil)
    #expect(Slug.normalize("   ") == nil)
}

@Test func slugFallbackHasExpectedShape() {
    let date = fixedDate(hour: 14, minute: 3)
    #expect(Slug.fallback(appName: "Zoom", at: date) == "meeting-zoom-1403")
}

@Test func slugFallbackDegradesGracefullyForUnusableAppName() {
    let date = fixedDate(hour: 9, minute: 30)
    #expect(Slug.fallback(appName: "!!!", at: date) == "meeting-app-0930")
}

// MARK: - ClaudeTitleGenerator

private struct FakeCommandRunner: CommandRunning {
    let result: Result<String, Error>

    func run(_ executable: String, _ args: [String], stdin: String?, timeout: TimeInterval) throws -> String {
        try result.get()
    }
}

@Test func titleGeneratorUsesGoodSlugFromCLI() async {
    let runner = FakeCommandRunner(result: .success("budget-review-q3\n"))
    let generator = ClaudeTitleGenerator(runner: runner)
    let slug = await generator.slug(for: sampleTranscript())
    #expect(slug == "budget-review-q3")
}

@Test func titleGeneratorFallsBackOnGarbageResponse() async {
    let runner = FakeCommandRunner(result: .success("..."))
    let generator = ClaudeTitleGenerator(runner: runner)
    let transcript = sampleTranscript()
    let slug = await generator.slug(for: transcript)
    #expect(slug == Slug.fallback(appName: transcript.appName, at: transcript.recordedAt))
}

@Test func titleGeneratorFallsBackOnTimeout() async {
    let runner = FakeCommandRunner(result: .failure(CommandRunnerError.timedOut))
    let generator = ClaudeTitleGenerator(runner: runner)
    let transcript = sampleTranscript()
    let slug = await generator.slug(for: transcript)
    #expect(slug == Slug.fallback(appName: transcript.appName, at: transcript.recordedAt))
}

@Test func titleGeneratorFallsBackOnMissingCLI() async {
    let runner = FakeCommandRunner(result: .failure(CommandRunnerError.notFound("claude")))
    let generator = ClaudeTitleGenerator(runner: runner)
    let transcript = sampleTranscript()
    let slug = await generator.slug(for: transcript)
    #expect(slug == Slug.fallback(appName: transcript.appName, at: transcript.recordedAt))
}

@Test func titleGeneratorFallsBackOnNonZeroExit() async {
    let runner = FakeCommandRunner(result: .failure(CommandRunnerError.nonZeroExit(1, "boom")))
    let generator = ClaudeTitleGenerator(runner: runner)
    let transcript = sampleTranscript()
    let slug = await generator.slug(for: transcript)
    #expect(slug == Slug.fallback(appName: transcript.appName, at: transcript.recordedAt))
}

// MARK: - MarkdownTranscriptWriter — golden render

@Test func markdownRendersExpectedGoldenFormat() {
    let transcript = Transcript(
        session: SessionID(raw: "2026-08-16T14-03-00"),
        recordedAt: fixedDate(hour: 14, minute: 3),
        duration: 49 * 60,
        appName: "Zoom",
        calendarTitle: "Mühlenbäcker Weekly",
        segments: [
            TranscriptSegment(
                start: 12, end: 15, track: .mic,
                speaker: "Sebastian", text: "Moin, danke dass du dir Zeit nimmst."
            ),
            TranscriptSegment(
                start: 19, end: 22, track: .remote,
                speaker: "Alex", text: "Klar, gerne."
            ),
        ]
    )

    let expected = """
    ---
    description: Meeting-Transkript Mühlenbäcker Weekly, 49 min
    updated: 2026-08-16
    teilnehmer: Sebastian, Alex
    quelle: open-transcribe (Zoom, 14:03-14:52)
    ---

    > Automatische Transkription, kann Fehler enthalten. Besonders betroffen sind englische Fachbegriffe und Eigennamen sowie Stellen, an denen ein Wort nicht in den Kontext passt. Im Zweifel gilt das Gesagte, nicht dieser Text.

    [00:00:12] Sebastian: Moin, danke dass du dir Zeit nimmst.
    [00:00:19] Alex: Klar, gerne.

    """

    #expect(MarkdownTranscriptWriter.render(transcript) == expected)
}

// MARK: - MarkdownTranscriptWriter — filesystem behavior

@Test func writerWritesHandlesCollisionAndRewritesInPlaceAtomically() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let wikiRaw = root.appendingPathComponent("wiki", isDirectory: true)
    try FileManager.default.createDirectory(at: wikiRaw, withIntermediateDirectories: true)
    let paths = Paths(root: root.appendingPathComponent("state"), wikiRaw: wikiRaw)

    let writer = MarkdownTranscriptWriter(paths: paths)
    var transcript = sampleTranscript()
    transcript.segments = [
        TranscriptSegment(start: 0, end: 1, track: .mic, speaker: "Sebastian", text: "Hallo."),
    ]

    let url1 = try writer.write(transcript, slug: "weekly-sync")
    #expect(url1.lastPathComponent == "2026-08-16-weekly-sync.md")
    #expect(FileManager.default.fileExists(atPath: url1.path))

    let url2 = try writer.write(transcript, slug: "weekly-sync")
    #expect(url2.lastPathComponent == "2026-08-16-weekly-sync-2.md")

    let entries = try FileManager.default.contentsOfDirectory(atPath: wikiRaw.path)
    #expect(entries.count == 2)
    #expect(entries.allSatisfy { !$0.hasSuffix(".tmp") })

    var renamed = transcript
    renamed.segments[0].speaker = "Renamed"
    let rewrittenURL = try writer.rewrite(renamed, at: url1)
    #expect(rewrittenURL == url1)

    let content = try String(contentsOf: url1, encoding: .utf8)
    #expect(content.contains("Renamed"))

    let entriesAfterRewrite = try FileManager.default.contentsOfDirectory(atPath: wikiRaw.path)
    #expect(entriesAfterRewrite.count == 2)
    #expect(entriesAfterRewrite.allSatisfy { !$0.hasSuffix(".tmp") })
}

@Test func writerThrowsOnMissingWikiDirectory() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = Paths(
        root: root.appendingPathComponent("state"),
        wikiRaw: root.appendingPathComponent("does-not-exist")
    )
    let writer = MarkdownTranscriptWriter(paths: paths)

    #expect(throws: (any Error).self) {
        try writer.write(sampleTranscript(), slug: "x")
    }
}

// MARK: - Fixtures

private func fixedDate(hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 16
    components.hour = hour
    components.minute = minute
    components.second = 0
    guard let date = calendar.date(from: components) else {
        preconditionFailure("fixed test date must be constructible")
    }
    return date
}

private func sampleTranscript() -> Transcript {
    Transcript(
        session: SessionID(raw: "2026-08-16T14-03-00"),
        recordedAt: fixedDate(hour: 14, minute: 3),
        duration: 60,
        appName: "Zoom",
        calendarTitle: nil,
        segments: []
    )
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Importance markers: a button pressed after the fact, so the flagged stretch reaches backwards.

@Test func importantRangesAreListedAndTheirLinesFlagged() throws {
    let transcript = Transcript(
        session: SessionID(raw: "2026-08-17T10-00-00"),
        recordedAt: Date(timeIntervalSince1970: 0),
        duration: 300,
        appName: "Zoom",
        calendarTitle: nil,
        segments: [
            TranscriptSegment(start: 10, end: 14, track: .mic, speaker: "Sebastian", text: "Vorher."),
            TranscriptSegment(start: 100, end: 104, track: .remote, speaker: "Alex", text: "Wichtiges."),
            TranscriptSegment(start: 200, end: 204, track: .mic, speaker: "Sebastian", text: "Danach."),
        ],
        importantRanges: [ImportantRange(start: 90, end: 130)]
    )

    let rendered = MarkdownTranscriptWriter.render(transcript)
    #expect(rendered.contains("wichtig: 00:01:30-00:02:10"))
    #expect(rendered.contains("**!** [00:01:40] Alex: Wichtiges."))
    #expect(rendered.contains("[00:00:10] Sebastian: Vorher."))
    #expect(!rendered.contains("**!** [00:00:10]"))
    #expect(!rendered.contains("**!** [00:03:20]"))
}

@Test func withoutMarkersNothingChanges() throws {
    let transcript = Transcript(
        session: SessionID(raw: "s"), recordedAt: Date(timeIntervalSince1970: 0), duration: 60,
        appName: "Zoom", calendarTitle: nil,
        segments: [TranscriptSegment(start: 0, end: 2, track: .mic, speaker: "Sebastian", text: "Hallo.")]
    )
    let rendered = MarkdownTranscriptWriter.render(transcript)
    #expect(!rendered.contains("wichtig:"))
    #expect(!rendered.contains("**!**"))
}

// Publishing: the ingest runs on a VPS and pulls from git, so an unpushed transcript is invisible.

@Test func publisherReportsWhichGitStepFailed() async throws {
    struct FailingRunner: CommandRunning {
        func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) throws -> String {
            if arguments.contains("push") { throw CommandRunnerError.nonZeroExit(1, "rejected") }
            return ""
        }
    }
    let repo = URL(fileURLWithPath: "/tmp/wiki")
    let publisher = GitWikiPublisher(repository: repo, runner: FailingRunner())
    let problem = await publisher.publish(repo.appendingPathComponent("raw/2026-08-17-test.md"))
    let message = try #require(problem)
    #expect(message.contains("raw/2026-08-17-test.md"))
    #expect(message.contains("push"))
}

@Test func publisherStaysQuietWhenEverythingWorked() async throws {
    struct OKRunner: CommandRunning {
        func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) throws -> String { "" }
    }
    let repo = URL(fileURLWithPath: "/tmp/wiki")
    let publisher = GitWikiPublisher(repository: repo, runner: OKRunner())
    #expect(await publisher.publish(repo.appendingPathComponent("raw/x.md")) == nil)
}

/// The publisher runs real `git`, so this exercises it against a throwaway repository with a
/// real remote. A mocked runner proves the call order; only this proves the commands work.
@Test func publisherCommitsAndPushesForReal() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ot-git-\(UUID().uuidString)", isDirectory: true)
    let remote = base.appendingPathComponent("remote.git")
    let work = base.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let git = ProcessCommandRunner()
    _ = try git.run("git", ["init", "--bare", remote.path], stdin: nil, timeout: 30)
    _ = try git.run("git", ["clone", remote.path, work.path], stdin: nil, timeout: 30)
    _ = try git.run("git", ["-C", work.path, "config", "user.email", "test@example.com"], stdin: nil, timeout: 30)
    _ = try git.run("git", ["-C", work.path, "config", "user.name", "Test"], stdin: nil, timeout: 30)

    // An empty repository has no branch to pull, so seed one first, like the real wiki has.
    let raw = work.appendingPathComponent("raw", isDirectory: true)
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("seed".utf8).write(to: raw.appendingPathComponent("README.md"))
    _ = try git.run("git", ["-C", work.path, "add", "."], stdin: nil, timeout: 30)
    _ = try git.run("git", ["-C", work.path, "commit", "-m", "seed"], stdin: nil, timeout: 30)
    _ = try git.run("git", ["-C", work.path, "push", "-u", "origin", "HEAD"], stdin: nil, timeout: 30)

    let transcript = raw.appendingPathComponent("2026-08-17-echter-test.md")
    try Data("---\ndescription: test\n---\n\n[00:00:00] Sebastian: Moin.\n".utf8).write(to: transcript)

    let problem = await GitWikiPublisher(repository: work).publish(transcript)
    #expect(problem == nil)

    // The file has to exist in the remote, not just locally.
    let listing = try git.run("git", ["-C", remote.path, "ls-tree", "-r", "--name-only", "HEAD"], stdin: nil, timeout: 30)
    #expect(listing.contains("raw/2026-08-17-echter-test.md"))
}

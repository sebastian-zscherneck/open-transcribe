import Foundation

// MARK: - Detection

/// What the detector reports upward. The detector itself never records anything.
public enum DetectionEvent: Sendable, Equatable {
    /// A trigger app has been holding the microphone long enough to count as a meeting.
    case meetingStarted(MeetingApp)
    /// The trigger app released the microphone long enough to count as over.
    case meetingEnded(MeetingApp)
}

/// Raw input for the detector: which processes currently capture audio input.
public struct AudioProcessSnapshot: Sendable, Equatable {
    public let bundleID: String
    public let pid: pid_t
    public let isRunningInput: Bool

    public init(bundleID: String, pid: pid_t, isRunningInput: Bool) {
        self.bundleID = bundleID
        self.pid = pid
        self.isRunningInput = isRunningInput
    }
}

/// Supplies snapshots of audio-capturing processes. Real implementation talks to CoreAudio,
/// the test implementation replays a scripted list.
public protocol AudioProcessSource: Sendable {
    func snapshot() throws -> [AudioProcessSnapshot]
}

public protocol MeetingDetecting: Sendable {
    /// Emits detection events until the returned task is cancelled.
    func events() -> AsyncStream<DetectionEvent>
}

// MARK: - Capture

/// Captures microphone and meeting-app audio into two separate 16 kHz mono tracks.
public protocol AudioCapturing: Sendable {
    /// Starts buffering into memory only. Nothing hits the disk yet.
    func startPrerollBuffer(app: MeetingApp) async throws
    /// Promotes the preroll buffer to a real on-disk recording.
    func commitToDisk(session: SessionID) async throws
    /// Drops the preroll buffer without ever having written to disk.
    func discardPreroll() async
    func pause() async
    func resume() async throws
    /// Stops capture and returns the finished track files.
    func stop() async throws -> [Track: URL]
    /// Samples recorded so far on a track, for the live preview.
    func recentSamples(track: Track, seconds: TimeInterval) async -> [Float]
}

// MARK: - Transcription

/// Turns the two recorded tracks into one chronological, speaker-attributed transcript.
public protocol Transcribing: Sendable {
    /// Loads models. Safe to call more than once.
    func prepare() async throws
    /// Quick pass over a chunk for the live panel preview.
    func transcribeLiveChunk(_ samples: [Float], track: Track, offset: TimeInterval) async throws -> [LiveLine]
    /// Full quality pass over both finished tracks.
    func finalPass(
        tracks: [Track: URL],
        context: FinalPassContext
    ) async throws -> Transcript
}

public struct FinalPassContext: Sendable {
    public let session: SessionID
    public let recordedAt: Date
    public let appName: String
    public let calendar: CalendarContext?
    /// Display name for the microphone track.
    public let ownerName: String

    public init(
        session: SessionID,
        recordedAt: Date,
        appName: String,
        calendar: CalendarContext?,
        ownerName: String
    ) {
        self.session = session
        self.recordedAt = recordedAt
        self.appName = appName
        self.calendar = calendar
        self.ownerName = ownerName
    }
}

// MARK: - Speakers

/// A known voice that a cluster was recognised as, with how far off it was.
public struct SpeakerMatch: Sendable, Equatable {
    public let name: String
    /// Cosine distance to the stored profile; 0 is identical, 1 is unrelated.
    public let distance: Float

    public init(name: String, distance: Float) {
        self.name = name
        self.distance = distance
    }
}

/// Persistent voice profiles so a known person is recognised in later meetings.
public protocol SpeakerProfiling: Sendable {
    /// Best matching known person for an embedding, or nil when nobody is close enough.
    func match(embedding: [Float]) async -> SpeakerMatch?
    /// Folds an embedding into a person's stored profile.
    func remember(name: String, embedding: [Float]) async throws
    func knownNames() async -> [String]
}

/// Ties a name the user just confirmed back to the voice it belonged to in the last final pass,
/// so the same person is recognised without asking next time.
public protocol SpeakerLearning: Sendable {
    func learn(label: String, as name: String) async
}

// MARK: - Calendar

public protocol CalendarReading: Sendable {
    /// The meeting-like event running at `date`, if the user granted access.
    func currentEvent(at date: Date) async -> CalendarContext?
}

// MARK: - Vocabulary

/// Repairs domain terms a speech model got wrong, without touching anything else.
public protocol TranscriptCorrecting: Sendable {
    func correct(_ transcript: Transcript) async -> Transcript
}

// MARK: - Output

/// Produces the wiki filename slug for a transcript.
public protocol TitleGenerating: Sendable {
    func slug(for transcript: Transcript) async -> String
}

/// Writes the transcript into the wiki inbox.
public protocol TranscriptWriting: Sendable {
    /// Returns the URL actually written.
    @discardableResult
    func write(_ transcript: Transcript, slug: String) throws -> URL
    /// Rewrites an already written file after a speaker was renamed.
    @discardableResult
    func rewrite(_ transcript: Transcript, at url: URL) throws -> URL
}

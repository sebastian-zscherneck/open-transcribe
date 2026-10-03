import Foundation

/// Identifier for one recording session. Stable, sortable, filesystem safe.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// `2026-08-16T14-03-11`
    public init(date: Date) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        self.raw = fmt.string(from: date)
    }

    public var description: String { raw }
}

/// Where the daemon currently is. One value, written to `state.json` on every transition.
public enum Phase: String, Codable, Sendable {
    case idle
    case detected
    case recording
    case paused
    case finalizing
    case written
    case error
}

/// The meeting application that triggered detection.
public struct MeetingApp: Codable, Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t

    public init(bundleID: String, name: String, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// Calendar context for the running meeting, if any. Read only, never a trigger.
public struct CalendarContext: Codable, Sendable, Equatable {
    public let title: String
    public let attendees: [String]
    public let startsAt: Date
    public let endsAt: Date

    public init(title: String, attendees: [String], startsAt: Date, endsAt: Date) {
        self.title = title
        self.attendees = attendees
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// A question the daemon needs the user to answer, surfaced by the notch UI.
public enum PendingQuestion: Codable, Sendable, Equatable {
    /// "Meeting erkannt, transkribieren?" — default answer is discard.
    case startRecording(app: MeetingApp, calendar: CalendarContext?, expiresAt: Date)
    /// "Wer war Speaker B?" — `candidates` are the voice-profile suggestion first, then the
    /// calendar attendees; `suggestion` names which candidate the voice pointed at; `sample` is
    /// something that speaker said so the user can tell who it was.
    case nameSpeaker(session: SessionID, label: String, candidates: [String], sample: String, suggestion: String?)
    /// "Unfertige Aufnahme gefunden, jetzt verschriften?"
    case recoverSession(session: SessionID, recordedAt: Date, duration: TimeInterval)
}

/// One line of the live preview shown in the notch panel. Never written to the wiki.
public struct LiveLine: Codable, Sendable, Equatable {
    public let at: TimeInterval
    public let speaker: String
    public let text: String

    public init(at: TimeInterval, speaker: String, text: String) {
        self.at = at
        self.speaker = speaker
        self.text = text
    }
}

/// Error surfaced to the UI. The daemon never fails silently.
public struct DaemonError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let recoverable: Bool

    public init(code: String, message: String, recoverable: Bool) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }
}

/// Full daemon state, serialised to `~/.opentranscribe/state.json` atomically.
public struct DaemonState: Codable, Sendable, Equatable {
    public var phase: Phase
    public var session: SessionID?
    public var app: MeetingApp?
    public var calendar: CalendarContext?
    public var startedAt: Date?
    public var recentLines: [LiveLine]
    public var pendingQuestion: PendingQuestion?
    public var lastWrittenFile: String?
    /// Speaker names of the last written transcript, so the UI can offer to correct one that
    /// was recognised wrongly. Empty outside `.written`.
    public var speakers: [String]
    public var error: DaemonError?
    public var updatedAt: Date

    public init(
        phase: Phase = .idle,
        session: SessionID? = nil,
        app: MeetingApp? = nil,
        calendar: CalendarContext? = nil,
        startedAt: Date? = nil,
        recentLines: [LiveLine] = [],
        pendingQuestion: PendingQuestion? = nil,
        lastWrittenFile: String? = nil,
        speakers: [String] = [],
        error: DaemonError? = nil,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.session = session
        self.app = app
        self.calendar = calendar
        self.startedAt = startedAt
        self.recentLines = recentLines
        self.pendingQuestion = pendingQuestion
        self.lastWrittenFile = lastWrittenFile
        self.speakers = speakers
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// Commands the UI drops into `~/.opentranscribe/commands/`.
public enum Command: Codable, Sendable, Equatable {
    case start
    case discard
    case pause
    case resume
    case stop
    case assignSpeaker(session: SessionID, label: String, name: String)
    case finalize(session: SessionID)
    /// Flags the couple of minutes that just happened as important.
    case markImportant
    /// Runs both capture sources for `seconds` and measures what actually comes back — sample
    /// count, peak and RMS per track — without going through the notch UI at all. `bundleID`
    /// picks which running app the remote (process tap) track listens to; nil falls back to
    /// whatever app is currently detected.
    case debugCapture(seconds: Int, bundleID: String?)
}

/// Which physical track a piece of audio came from.
public enum Track: String, Codable, Sendable {
    /// The local microphone. By definition the owner of the machine.
    case mic
    /// The meeting application's output, i.e. everyone else.
    case remote
}

/// One attributed utterance in the final transcript.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let track: Track
    /// Resolved display name, or a placeholder such as `Speaker B`.
    public var speaker: String
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, track: Track, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.track = track
        self.speaker = speaker
        self.text = text
    }
}

/// A stretch of the meeting the user flagged as important while it was running.
///
/// Marked retroactively: nobody presses a button in the middle of the sentence that matters, so
/// the button marks the couple of minutes that just happened.
public struct ImportantRange: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public func overlaps(start segmentStart: TimeInterval, end segmentEnd: TimeInterval) -> Bool {
        segmentStart < end && segmentEnd > start
    }
}

/// The finished transcript, ready to be written to the wiki.
public struct Transcript: Codable, Sendable, Equatable {
    public let session: SessionID
    public let recordedAt: Date
    public let duration: TimeInterval
    public let appName: String
    public let calendarTitle: String?
    public var segments: [TranscriptSegment]
    public var importantRanges: [ImportantRange]
    /// Who an unresolved `Speaker X` probably is, judged by voice against stored profiles.
    /// A guess for the user to confirm, never applied on its own: voices of different people
    /// have been measured as close to a profile as the person themselves.
    public var speakerSuggestions: [String: String]

    public init(
        session: SessionID,
        recordedAt: Date,
        duration: TimeInterval,
        appName: String,
        calendarTitle: String?,
        segments: [TranscriptSegment],
        importantRanges: [ImportantRange] = [],
        speakerSuggestions: [String: String] = [:]
    ) {
        self.importantRanges = importantRanges
        self.speakerSuggestions = speakerSuggestions
        self.session = session
        self.recordedAt = recordedAt
        self.duration = duration
        self.appName = appName
        self.calendarTitle = calendarTitle
        self.segments = segments
    }

    /// Distinct speaker names in order of first appearance.
    public var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}

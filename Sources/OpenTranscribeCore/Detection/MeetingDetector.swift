import Foundation

/// Pure, synchronous decision core. No clock, no concurrency, no CoreAudio — just snapshots in,
/// events out. This is what the tests exercise directly with a fake clock.
public struct DetectionEngine: Sendable {
    private struct Candidate {
        let app: MeetingApp
        let since: Date
    }

    private struct ActiveMeeting {
        var app: MeetingApp
        var lastRunningAt: Date
    }

    private let settings: DetectionSettings
    private var candidates: [String: Candidate] = [:]
    private var active: ActiveMeeting?

    public init(settings: DetectionSettings) {
        self.settings = settings
    }

    /// Advances the state machine by one snapshot and returns an event, if any transition fired.
    public mutating func step(snapshots: [AudioProcessSnapshot], now: Date) -> DetectionEvent? {
        // A helper process is folded into the app it belongs to, so Chrome's audio helper and
        // Chrome itself are one candidate rather than two.
        let triggerRunning: [(trigger: String, snapshot: AudioProcessSnapshot)] = snapshots.compactMap {
            guard $0.isRunningInput, let trigger = settings.trigger(for: $0.bundleID) else { return nil }
            return (trigger, $0)
        }
        let runningBundleIDs = Set(triggerRunning.map(\.trigger))

        if var current = active {
            if runningBundleIDs.contains(current.app.bundleID) {
                current.lastRunningAt = now
                active = current
                return nil
            }
            let gap = now.timeIntervalSince(current.lastRunningAt)
            if gap >= settings.endDebounce {
                active = nil
                candidates.removeAll()
                return .meetingEnded(current.app)
            }
            active = current
            return nil
        }

        // Only continuous running counts: drop candidates that fell silent.
        for bundleID in candidates.keys where !runningBundleIDs.contains(bundleID) {
            candidates.removeValue(forKey: bundleID)
        }
        for entry in triggerRunning where candidates[entry.trigger] == nil {
            candidates[entry.trigger] = Candidate(
                app: MeetingApp(
                    bundleID: entry.trigger,
                    name: Self.friendlyName(for: entry.trigger),
                    // The pid of the process actually capturing, which is the one worth tapping.
                    pid: entry.snapshot.pid
                ),
                since: now
            )
        }

        // Multiple simultaneous candidates: the one that qualified first wins.
        let qualified = candidates.values
            .filter { now.timeIntervalSince($0.since) >= settings.startDebounce }
            .sorted { $0.since < $1.since }
        guard let winner = qualified.first else { return nil }

        active = ActiveMeeting(app: winner.app, lastRunningAt: now)
        candidates.removeAll()
        return .meetingStarted(winner.app)
    }

    private static let knownAppNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.apple.Safari": "Safari",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
    ]

    private static func friendlyName(for bundleID: String) -> String {
        knownAppNames[bundleID] ?? bundleID
    }
}

/// Polls `source` on `settings.pollInterval` and threads results through `DetectionEngine`.
/// All time- and IO-dependent behavior lives here; the engine itself stays pure and testable.
public final class MeetingDetector: MeetingDetecting, Sendable {
    private let source: AudioProcessSource
    private let settings: DetectionSettings

    public init(source: AudioProcessSource, settings: DetectionSettings) {
        self.source = source
        self.settings = settings
    }

    public func events() -> AsyncStream<DetectionEvent> {
        let source = source
        let settings = settings
        return AsyncStream { continuation in
            let task = Task {
                var engine = DetectionEngine(settings: settings)
                while !Task.isCancelled {
                    if let snapshots = try? source.snapshot(),
                       let event = engine.step(snapshots: snapshots, now: Date()) {
                        continuation.yield(event)
                    }
                    try? await Task.sleep(for: .milliseconds(Int(settings.pollInterval * 1000)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

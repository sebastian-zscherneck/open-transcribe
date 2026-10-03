import Foundation

/// User-tunable detection knobs. Persisted to `Paths.settingsFile`, falls back to defaults
/// whenever the file is missing or malformed — detection must never crash on bad config.
public struct DetectionSettings: Codable, Sendable, Equatable {
    public var triggerBundleIDs: Set<String>
    public var ignoredBundleIDs: Set<String>
    public var startDebounce: TimeInterval
    public var endDebounce: TimeInterval
    public var pollInterval: TimeInterval
    /// Input devices to record from, best first, matched against the device name. The built-in
    /// microphone is the last resort because a closed MacBook still advertises it as the system
    /// default while delivering silence.
    public var preferredInputDevices: [String]

    public init(
        triggerBundleIDs: Set<String>,
        ignoredBundleIDs: Set<String>,
        startDebounce: TimeInterval,
        endDebounce: TimeInterval,
        pollInterval: TimeInterval,
        preferredInputDevices: [String] = ["AirPods", "PC-LM1E"]
    ) {
        self.preferredInputDevices = preferredInputDevices
        self.triggerBundleIDs = triggerBundleIDs
        self.ignoredBundleIDs = ignoredBundleIDs
        self.startDebounce = startDebounce
        self.endDebounce = endDebounce
        self.pollInterval = pollInterval
    }

    public static var defaults: DetectionSettings {
        DetectionSettings(
            triggerBundleIDs: [
                "us.zoom.xos",
                "com.microsoft.teams2",
                "com.microsoft.teams",
                "com.tinyspeck.slackmacgap",
                "com.google.Chrome",
                "company.thebrowser.Browser",
                "com.apple.Safari",
                "com.apple.FaceTime",
                "com.hnc.Discord",
            ],
            ignoredBundleIDs: [
                "com.sebastianzscherneck.opentranscribe",
                "com.local.wisper-clone",
                "com.apple.SpeechRecognitionCore",
            ],
            startDebounce: 15,
            endDebounce: 20,
            pollInterval: 2,
            preferredInputDevices: ["AirPods", "PC-LM1E"]
        )
    }

    /// The trigger this bundle belongs to, or nil.
    ///
    /// Electron apps and browsers hold the microphone in a helper process
    /// (`com.google.Chrome.helper`, `com.tinyspeck.slackmacgap.helper`), never in the process
    /// carrying the app's own bundle id. Matching the helper back to its parent is therefore not
    /// a convenience: without it, every browser meeting goes unnoticed.
    public func trigger(for bundleID: String) -> String? {
        guard !isIgnored(bundleID) else { return nil }
        if triggerBundleIDs.contains(bundleID) { return bundleID }
        return triggerBundleIDs.first { bundleID.hasPrefix($0 + ".") }
    }

    /// Ignoring follows the same parent-child rule, so a helper of an ignored app stays ignored.
    public func isIgnored(_ bundleID: String) -> Bool {
        if ignoredBundleIDs.contains(bundleID) { return true }
        return ignoredBundleIDs.contains { bundleID.hasPrefix($0 + ".") }
    }

    /// Loads from disk, silently falling back to defaults on any error.
    public static func load(from paths: Paths) -> DetectionSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return .defaults }
        return (try? OTJSON.decoder.decode(DetectionSettings.self, from: data)) ?? .defaults
    }
}

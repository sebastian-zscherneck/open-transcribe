import Foundation
import Testing
@testable import OpenTranscribeCore

private let epoch = Date(timeIntervalSince1970: 0)

private func snapshot(_ bundleID: String, pid: pid_t = 1, running: Bool = true) -> AudioProcessSnapshot {
    AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
}

private let testSettings = DetectionSettings(
    triggerBundleIDs: ["us.zoom.xos", "com.microsoft.teams2"],
    ignoredBundleIDs: ["com.sebastianzscherneck.opentranscribe"],
    startDebounce: 15,
    endDebounce: 20,
    pollInterval: 2
)

@Test func triggerUnderDebounceDoesNotFire() {
    var engine = DetectionEngine(settings: testSettings)
    let t0 = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch)
    let t1 = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(10))
    #expect(t0 == nil)
    #expect(t1 == nil)
}

@Test func triggerOverDebounceFiresExactlyOnce() {
    var engine = DetectionEngine(settings: testSettings)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch)
    let started = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(15))
    let again = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(16))
    guard case .meetingStarted(let app)? = started else {
        Issue.record("expected meetingStarted, got \(String(describing: started))")
        return
    }
    #expect(app.bundleID == "us.zoom.xos")
    #expect(again == nil)
}

@Test func shortGapUnderEndDebounceDoesNotEnd() {
    var engine = DetectionEngine(settings: testSettings)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(15))
    let gapped = engine.step(snapshots: [], now: epoch.addingTimeInterval(25))
    let backAgain = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(30))
    #expect(gapped == nil)
    #expect(backAgain == nil)
}

@Test func longGapEndsExactlyOnce() {
    var engine = DetectionEngine(settings: testSettings)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(15))
    let stillGone = engine.step(snapshots: [], now: epoch.addingTimeInterval(30))
    let ended = engine.step(snapshots: [], now: epoch.addingTimeInterval(36))
    let afterEnd = engine.step(snapshots: [], now: epoch.addingTimeInterval(40))
    #expect(stillGone == nil)
    guard case .meetingEnded(let app)? = ended else {
        Issue.record("expected meetingEnded, got \(String(describing: ended))")
        return
    }
    #expect(app.bundleID == "us.zoom.xos")
    #expect(afterEnd == nil)
}

@Test func ignoredBundleNeverFires() {
    var engine = DetectionEngine(
        settings: DetectionSettings(
            triggerBundleIDs: ["com.sebastianzscherneck.opentranscribe"],
            ignoredBundleIDs: ["com.sebastianzscherneck.opentranscribe"],
            startDebounce: 15,
            endDebounce: 20,
            pollInterval: 2
        )
    )
    let event = engine.step(
        snapshots: [snapshot("com.sebastianzscherneck.opentranscribe")],
        now: epoch.addingTimeInterval(100)
    )
    #expect(event == nil)
}

@Test func nonTriggerAppNeverFires() {
    var engine = DetectionEngine(settings: testSettings)
    let event = engine.step(snapshots: [snapshot("com.apple.Finder")], now: epoch.addingTimeInterval(100))
    #expect(event == nil)
}

@Test func secondTriggerAppDuringMeetingProducesNoSecondEvent() {
    var engine = DetectionEngine(settings: testSettings)
    _ = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch)
    let started = engine.step(snapshots: [snapshot("us.zoom.xos")], now: epoch.addingTimeInterval(15))
    guard case .meetingStarted? = started else {
        Issue.record("expected meetingStarted")
        return
    }

    // Teams joins mid-meeting and stays past its own start debounce; no second event should fire.
    _ = engine.step(
        snapshots: [snapshot("us.zoom.xos"), snapshot("com.microsoft.teams2")],
        now: epoch.addingTimeInterval(20)
    )
    let stillNothing = engine.step(
        snapshots: [snapshot("us.zoom.xos"), snapshot("com.microsoft.teams2")],
        now: epoch.addingTimeInterval(40)
    )
    #expect(stillNothing == nil)
}

// Browsers and Electron apps capture in a helper process. Real CoreAudio output on this machine
// shows `com.google.Chrome.helper` holding the microphone while `com.google.Chrome` does not, so
// exact bundle matching would miss every browser meeting.

private let helperSettings = DetectionSettings(
    triggerBundleIDs: ["com.google.Chrome", "com.tinyspeck.slackmacgap"],
    ignoredBundleIDs: ["com.local.wisper-clone"],
    startDebounce: 15,
    endDebounce: 20,
    pollInterval: 2
)

@Test func helperProcessCountsAsItsParentApp() {
    var engine = DetectionEngine(settings: helperSettings)
    _ = engine.step(snapshots: [snapshot("com.google.Chrome.helper", pid: 17350)], now: epoch)
    let event = engine.step(
        snapshots: [snapshot("com.google.Chrome.helper", pid: 17350)],
        now: epoch.addingTimeInterval(15)
    )

    guard case .meetingStarted(let app)? = event else {
        Issue.record("expected meetingStarted, got \(String(describing: event))")
        return
    }
    #expect(app.bundleID == "com.google.Chrome")
    #expect(app.name == "Chrome")
    // The capturing process is the helper, and that is the pid worth tapping.
    #expect(app.pid == 17350)
}

@Test func helperAndParentAreOneCandidateNotTwo() {
    var engine = DetectionEngine(settings: helperSettings)
    let both = [snapshot("com.google.Chrome", pid: 16997), snapshot("com.google.Chrome.helper", pid: 17350)]
    _ = engine.step(snapshots: both, now: epoch)
    let started = engine.step(snapshots: both, now: epoch.addingTimeInterval(15))
    guard case .meetingStarted? = started else {
        Issue.record("expected meetingStarted")
        return
    }
    #expect(engine.step(snapshots: both, now: epoch.addingTimeInterval(30)) == nil)
}

@Test func helperOfAnIgnoredAppStaysIgnored() {
    var engine = DetectionEngine(settings: helperSettings)
    _ = engine.step(snapshots: [snapshot("com.local.wisper-clone.helper")], now: epoch)
    let event = engine.step(
        snapshots: [snapshot("com.local.wisper-clone.helper")],
        now: epoch.addingTimeInterval(60)
    )
    #expect(event == nil)
}

@Test func aSimilarlyNamedAppIsNotMistakenForATrigger() {
    var engine = DetectionEngine(settings: helperSettings)
    // Prefix matching must respect the dot boundary, or "com.google.ChromeCast" would count.
    _ = engine.step(snapshots: [snapshot("com.google.ChromeCast")], now: epoch)
    let event = engine.step(snapshots: [snapshot("com.google.ChromeCast")], now: epoch.addingTimeInterval(60))
    #expect(event == nil)
}

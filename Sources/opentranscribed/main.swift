import AppKit
import Foundation
import OpenTranscribeCore
import UserNotifications

/// The background agent. It owns the permissions, runs the coordinator, and keeps a menu bar
/// item as the way out when OpenNotch is not installed or not running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = Paths.live
    private var statusItem: NSStatusItem?
    private var coordinatorTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private lazy var commands = CommandQueue(paths: paths)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try paths.createDirectories()
        } catch {
            NSLog("open-transcribe: cannot create \(paths.root.path): \(error)")
        }

        installMenuBarItem()
        requestNotificationPermission()
        startCoordinator()

        // The menu bar title mirrors the state file, which is also what the notch renders.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBar() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinatorTask?.cancel()
        refreshTimer?.invalidate()
    }

    private func startCoordinator() {
        let settings = DetectionSettings.load(from: paths)
        let profiles = ProfileStore(paths: paths)
        let transcriber = FluidTranscriber(profiles: profiles)
        let terms = PersonalDictionary.load(paths: paths)

        let coordinator = SessionCoordinator(
            paths: paths,
            detector: MeetingDetector(source: CoreAudioProcessSource(), settings: settings),
            capture: AudioCaptureCoordinator(
                paths: paths,
                makeMicSource: { MicCapture(preferredDevices: settings.preferredInputDevices) }
            ),
            transcriber: transcriber,
            calendar: NoCalendar(),
            titles: ClaudeTitleGenerator(),
            writer: MarkdownTranscriptWriter(paths: paths),
            state: StateStore(paths: paths),
            commands: commands,
            learner: transcriber,
            corrector: FoundationModelsCorrector(terms: terms, aliases: PersonalDictionary.loadAliases(paths: paths)),
            publisher: GitWikiPublisher(
                repository: paths.wikiRaw.deletingLastPathComponent()
            )
        )

        coordinatorTask = Task.detached(priority: .utility) {
            do {
                try await coordinator.run()
            } catch {
                NSLog("open-transcribe: coordinator stopped: \(error)")
            }
        }

        // Models are large; warming them at launch keeps the first meeting from waiting.
        Task.detached(priority: .background) {
            try? await transcriber.prepare()
        }
    }

    // MARK: - Menu bar

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "○"
        item.button?.toolTip = "OpenTranscribe"
        statusItem = item
        refreshMenuBar()
    }

    private func refreshMenuBar() {
        let state = StateStore.loadPersisted(paths: paths)
        let menu = NSMenu()

        switch state.phase {
        case .idle:
            statusItem?.button?.title = "○"
            menu.addItem(NSMenuItem(title: "Kein Meeting", action: nil, keyEquivalent: ""))
        case .detected:
            statusItem?.button?.title = "◎"
            menu.addItem(NSMenuItem(title: "Meeting erkannt: \(state.app?.name ?? "?")", action: nil, keyEquivalent: ""))
            menu.addItem(item("Transkribieren", #selector(sendStart)))
            menu.addItem(item("Nicht jetzt", #selector(sendDiscard)))
        case .recording, .paused:
            statusItem?.button?.title = state.phase == .paused ? "❙❙" : "●"
            let minutes = Int(Date().timeIntervalSince(state.startedAt ?? Date()) / 60)
            menu.addItem(NSMenuItem(title: "Läuft seit \(minutes) min", action: nil, keyEquivalent: ""))
            menu.addItem(item(state.phase == .paused ? "Fortsetzen" : "Pause",
                              state.phase == .paused ? #selector(sendResume) : #selector(sendPause)))
            menu.addItem(item("Stoppen und verschriften", #selector(sendStop)))
        case .finalizing:
            statusItem?.button?.title = "⋯"
            menu.addItem(NSMenuItem(title: "Transkribiert…", action: nil, keyEquivalent: ""))
        case .written:
            statusItem?.button?.title = "✓"
            let name = (state.lastWrittenFile as NSString?)?.lastPathComponent ?? "geschrieben"
            menu.addItem(item(name, #selector(revealLastFile)))
        case .error:
            statusItem?.button?.title = "!"
            menu.addItem(NSMenuItem(title: state.error?.message ?? "Fehler", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        menu.addItem(item("Aufnahmen im Finder", #selector(revealRecordings)))
        menu.addItem(item("Beenden", #selector(quit)))
        statusItem?.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Actions

    @objc private func sendStart() { try? commands.send(.start) }
    @objc private func sendDiscard() { try? commands.send(.discard) }
    @objc private func sendPause() { try? commands.send(.pause) }
    @objc private func sendResume() { try? commands.send(.resume) }
    @objc private func sendStop() { try? commands.send(.stop) }

    @objc private func revealLastFile() {
        guard let path = StateStore.loadPersisted(paths: paths).lastWrittenFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func revealRecordings() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.recordingsDir])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

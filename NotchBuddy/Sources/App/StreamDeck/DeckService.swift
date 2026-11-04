import AppKit
import Combine
import Foundation

// MARK: - Stream deck: the bridge to the island (GitHub build)
//
// Drives a Redragon SS552 / Mirabox N4-family deck from Coucou: the live agent sessions on the keys,
// a permission request or a question taking over the keys when one is waiting, plan usage, the
// selected session, music and Mochi on the touch strip. Off by default (Settings → General).
//
// Event driven like the Android link: AppState and the music and dictation models are observed,
// debounced, and only the screens whose tile changed are redrawn. While the switch is off nothing
// is opened and no timer runs.
//
// A decision from the deck goes through HookServer.sendApprovalDecision with the id of the request
// the deck showed, the path a click on the island's own card takes. DeckLayout decides what each
// control does (tested in tests/DeckProtocolTests.swift).

#if !APPSTORE

@MainActor
final class DeckService: ObservableObject {
    static let shared = DeckService()
    static let enabledKey = "streamDeckEnabled"
    static let brightnessKey = "streamDeckBrightness"

    @Published private(set) var connected = false

    private let device = DeckDevice()
    private var cancellables: Set<AnyCancellable> = []
    private var minuteTimer: Timer?
    /// What each screen shows now: only a changed tile is drawn again.
    private var drawn: [DeckProtocol.Screen: DeckTile] = [:]
    private var selected = 0
    private var armClock = DeckArmClock()
    private var screensOn = true
    private var brightness: Int {
        get { UserDefaults.standard.object(forKey: Self.brightnessKey) as? Int ?? 70 }
        set { UserDefaults.standard.set(newValue, forKey: Self.brightnessKey) }
    }
    private let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// At launch: starts only if the user turned it on.
    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    // MARK: Start and stop

    private var running = false

    private func start() {
        guard !running else { return }
        running = true
        device.onEvent = { [weak self] event in self?.handle(event) }
        device.onConnection = { [weak self] on in self?.connectionChanged(on) }
        device.onWriteFailed = { [weak self] in self?.drawn = [:] }
        device.start()
        observe()
    }

    /// At quit: clears the deck without touching the saved switch.
    func shutdown() { stop() }

    private func stop() {
        guard running else { return }
        running = false
        cancellables = []
        minuteTimer?.invalidate()
        minuteTimer = nil
        if device.isConnected {
            device.send([DeckProtocol.clearAll(), DeckProtocol.commit()])
        }
        device.stop()
        drawn = [:]
        connected = false
    }

    private func connectionChanged(_ on: Bool) {
        connected = on
        drawn = [:]
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard on else { return }
        screensOn = true
        // A request already waiting is shown again from scratch: its keys wait again.
        armClock = DeckArmClock()
        device.send([DeckProtocol.brightness(brightness)])
        // The clock on the Mochi panel: one tick on each minute while a deck is plugged in.
        let nextMinute = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
        redraw()
    }

    // MARK: Observing the app

    private func observe() {
        let s = AppState.shared
        let spotify = SpotifyController.shared
        let music = MusicController.shared
        let sources: [AnyPublisher<Void, Never>] = [
            s.$tasks.map { _ in () }.eraseToAnyPublisher(),
            s.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            s.$waitingQuestions.map { _ in () }.eraseToAnyPublisher(),
            s.$claudePlanUsage.map { _ in () }.eraseToAnyPublisher(),
            s.$musicPlaying.map { _ in () }.eraseToAnyPublisher(),
            spotify.$track.map { _ in () }.eraseToAnyPublisher(),
            spotify.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            spotify.$artwork.map { _ in () }.eraseToAnyPublisher(),
            music.$trackTitle.map { _ in () }.eraseToAnyPublisher(),
            NoteTaker.shared.$recording.map { _ in () }.eraseToAnyPublisher(),
            FlowDictation.shared.$isEnabled.map { _ in () }.eraseToAnyPublisher(),
            FlowDictation.shared.pill.model.$phase.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the property changes: the debounce lets the value settle, and it is read back.
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.redraw() } }
            .store(in: &cancellables)
    }

    // MARK: The app's state, as the deck sees it

    private static let noAlways: Set<String> = ["agent_codex", "agent_copilot", "agent_muse"]

    private func snapshot() -> DeckSnapshot {
        let app = AppState.shared
        var s = DeckSnapshot()
        // The demo is not real: the deck shows none of it.
        if !DemoEngine.shared.isActive {
            s.sessions = app.tasks
                .filter { $0.source != .n8n && PillCatalog.isSession($0.id) }
                .map { task in
                    let step = task.steps.indices.contains(task.stepIndex) ? task.steps[task.stepIndex] : (task.steps.last ?? "")
                    return .init(id: task.id, agent: task.name,
                                 project: task.sessionCwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                                 state: task.state.rawValue, step: step, color: task.color)
                }
            if let a = app.pendingApproval, a.sessionId != "demo_session" {
                s.approval = .init(id: a.id, tool: a.tool, command: a.command, project: a.projectName,
                                   allowsAlways: !Self.noAlways.contains(PillCatalog.basePillId(a.pillId)),
                                   isPlan: a.tool == "ExitPlanMode")
            }
            if let entry = app.waitingQuestions.first {
                let items = entry.question.questions
                // One key, one answer: a single single-choice question whose options all fit on the keys.
                let oneKey = items.count == 1 && !items[0].multiSelect
                    && (1...DeckLayout.maxSessionKeys).contains(items[0].options.count)
                s.question = .init(id: entry.id, project: entry.projectName, text: items.first?.question ?? "",
                                   options: oneKey ? items[0].options.map(\.label) : [])
            }
        }
        if let usage = app.claudePlanUsage {
            s.planFiveHour = usage.fiveHour.map(ClaudePlanGauge.effectivePct)
            s.planWeek = usage.sevenDay.map(ClaudePlanGauge.effectivePct)
        }
        let spotify = SpotifyController.shared
        if let track = spotify.track {
            // The artwork arrives after the track: the key changes with it so the panel is drawn again.
            s.music = .init(title: track.title, artist: track.artist, playing: spotify.isPlaying,
                            artworkKey: spotify.artwork != nil ? track.id : nil)
        } else if let title = MusicController.shared.trackTitle {
            s.music = .init(title: title, artist: MusicController.shared.artist ?? "", playing: app.musicPlaying, artworkKey: nil)
        }
        let flow = FlowDictation.shared
        if !flow.isEnabled {
            s.dictation = .off
        } else {
            switch flow.pill.model.phase {
            case .listening, .locked: s.dictation = .listening
            case .thinking: s.dictation = .thinking
            default: s.dictation = .idle
            }
        }
        s.recordingAvailable = true
        s.recording = NoteTaker.shared.isRecording
        s.overallState = app.effectiveState.rawValue
        s.clock = clockFormat.string(from: Date())
        return s
    }

    // MARK: Drawing

    private func redraw() {
        guard device.isConnected else { return }
        let s = snapshot()
        // Screens turned off with knob 1: a request waiting for the user lights them up again.
        if !screensOn, DeckLayout.requestId(s) != nil {
            screensOn = true
            armClock = DeckArmClock() // the request was not visible: its keys wait from now
            device.send([DeckProtocol.brightness(brightness)])
        }
        guard screensOn else { return }
        armClock.update(requestId: DeckLayout.requestId(s), now: Date())
        selected = DeckLayout.clampedSelection(selected, s)
        let tiles = DeckLayout.tiles(s, selected: selected)
        var reports: [[UInt8]] = []
        for screen in DeckProtocol.Screen.all {
            guard let tile = tiles[screen], drawn[screen] != tile else { continue }
            guard let jpeg = DeckRenderer.jpeg(tile, on: screen, artwork: artwork(for: tile)) else {
                DeckDevice.log("could not draw \(screen)")
                continue
            }
            reports += DeckProtocol.image(jpeg, on: screen)
            drawn[screen] = tile
        }
        guard !reports.isEmpty else { return }
        reports.append(DeckProtocol.commit())
        device.send(reports)
    }

    private func artwork(for tile: DeckTile) -> NSImage? {
        guard case .music(let m?) = tile, m.artworkKey != nil else { return nil }
        return SpotifyController.shared.artwork
    }

    // MARK: Controls

    private func handle(_ event: DeckProtocol.Event) {
        // Screens off: the first touch only wakes them, it never acts. Releasing the dictation key still
        // ends a dictation, so a hands-free dictation never keeps listening behind dark screens.
        let releasesDictation = event == .keyUp(DeckLayout.dictationKey)
        if !screensOn && !releasesDictation {
            screensOn = true
            armClock = DeckArmClock() // a request was not visible: its keys wait from now
            device.send([DeckProtocol.brightness(brightness)])
            redraw()
            return
        }
        // Read live, not the last drawn picture: a request that just arrived is not armed yet.
        let s = snapshot()
        let armed = armClock.armed(for: DeckLayout.requestId(s), now: Date())
        guard let action = DeckLayout.action(for: event, s, selected: selected, armed: armed) else { return }
        perform(action)
    }

    private func perform(_ action: DeckAction) {
        let app = AppState.shared
        let spotifyActive = SpotifyController.shared.track != nil
        switch action {
        case .decide(let id, let decision):
            // The request must still be the one the deck showed.
            guard app.pendingApproval?.id == id else { return }
            DeckDevice.log("\(decision) from the deck: \(app.pendingApproval?.tool ?? "")")
            HookServer.shared.sendApprovalDecision(decision, for: id)
        case .answer(let id, let label):
            guard let entry = app.waitingQuestions.first(where: { $0.id == id }) else { return }
            DeckDevice.log("answered a question from the deck") // never what was picked
            HookServer.shared.sendQuestionAnswers(
                AskQuestion.buildAnswers(questions: entry.question.questions, selections: [[label]]), for: id)
        case .answerInTerminal(let id):
            HookServer.shared.sendQuestionAsk(for: id)
        case .jumpToRequest:
            (NSApp.delegate as? AppDelegate)?.islandController?.handleHotKey(.jumpToTerminal)
        case .jump(let sessionId):
            jump(to: app.tasks.first { $0.id == sessionId })
        case .dictationStart:
            FlowDictation.shared.startHandsFree()
        case .dictationStop:
            FlowDictation.shared.finishFromPill()
        case .toggleRecording:
            NoteTaker.shared.toggleFromPill()
        case .brightness(let delta):
            brightness = max(10, min(100, brightness + delta))
            device.send([DeckProtocol.brightness(brightness)])
        case .toggleScreens:
            screensOn = false
            device.send([DeckProtocol.brightness(0)])
        case .select(let delta):
            selected += delta
            redraw()
        case .musicPlayPause:
            if spotifyActive { SpotifyController.shared.playPause() } else { MusicController.shared.playPause() }
        case .musicNext:
            if spotifyActive { SpotifyController.shared.nextTrack() } else { MusicController.shared.nextTrack() }
        case .volume(let delta):
            // Apple Music's volume has no "is it running" check: it would launch the app.
            if spotifyActive {
                SpotifyController.shared.adjustVolume(by: delta)
            } else if MusicController.shared.trackTitle != nil {
                MusicController.shared.adjustVolume(by: delta)
            }
        case .openCoucou:
            FlowHubController.shared.show()
        }
    }

    /// Same routing as the island's "Open terminal" (IslandViewContent).
    private func jump(to task: AgentTask?) {
        guard let task else { return }
        if !(task.pill == "integration_claude" && ClaudeHost.activate(task.hostApp)),
           !TerminalTarget.activate(sessionBundleId: task.sessionBundleId) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}

#endif

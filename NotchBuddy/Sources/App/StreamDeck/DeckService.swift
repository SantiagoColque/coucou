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
    private var page: DeckPage = .agents
    private var lastRequestId: UUID?
    /// The focus timer: when it ends, and its length (seconds).
    private var focusEnd: Date?
    private var focusTotal = 0
    private var focusIsBreak = false
    private var secondTimer: Timer?
    private let vitals = DeckVitals()
    private var lastVitals: DeckSnapshot.Vitals?
    private var vitalsTimer: Timer?
    private var audioListening = false
    /// The free key whose sleeping Mochi a press woke, and the nap that follows.
    private var awakeSlot: Int?
    private var napWork: DispatchWorkItem?
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
        SpotifyController.shared.followForDeck()
    }

    /// At quit: clears the deck without touching the saved switch.
    func shutdown() { stop() }

    private func stop() {
        guard running else { return }
        running = false
        cancellables = []
        minuteTimer?.invalidate()
        minuteTimer = nil
        stopFocusTimer()
        updateVitalsTimer(on: false)
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
        guard on else { updateVitalsTimer(on: false); return }
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
            Parakeet.shared.$state.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the property changes: the debounce lets the value settle, and it is read back.
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.redraw() } }
            .store(in: &cancellables)
        // A new default microphone or output (AirPods put on) shows at once. CoreAudio listeners live
        // as long as the app: added once, they only ask for a redraw, which does nothing while the deck is off.
        if !audioListening {
            audioListening = true
            _ = DeckAudio.observe { [weak self] in self?.redraw() }
        }
    }

    // MARK: The app's state, as the deck sees it

    private static let noAlways: Set<String> = ["agent_codex", "agent_copilot", "agent_muse"]

    /// A session's key on the deck: its hook session id, stable across launches and when it pops
    /// in or out of a shared pill; the pill's id for an agent without one.
    private static func deckId(session: String?, task: AgentTask) -> String {
        session.map { "s:" + $0 } ?? task.id
    }

    /// The task a deck session belongs to.
    private static func task(for deckId: String, in tasks: [AgentTask]) -> AgentTask? {
        if deckId.hasPrefix("s:") {
            let key = String(deckId.dropFirst(2))
            return tasks.first { $0.sessionKey == key } ?? tasks.first { $0.sessionLines.contains { $0.id == key } }
        }
        return tasks.first { $0.id == deckId }
    }

    // MARK: Session order

    private static let orderKey = "streamDeckSessionOrder"
    private static let spotsKey = "streamDeckSessionSpots"
    /// Every session keeps its key: the order they were first seen, corrected by where their
    /// windows or panes were found on screen when jumping to them.
    private lazy var sessionOrder: [String] = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
    private lazy var sessionSpots: [String: CGPoint] = {
        let raw = UserDefaults.standard.dictionary(forKey: Self.spotsKey) as? [String: [Double]] ?? [:]
        return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }()

    private func ordered(_ sessions: [DeckSnapshot.Session]) -> [DeckSnapshot.Session] {
        let new = sessions.map(\.id).filter { !sessionOrder.contains($0) }
        if !new.isEmpty {
            sessionOrder += new
            // Sessions long gone drop off the front.
            let live = Set(sessions.map(\.id))
            while sessionOrder.count > 40, let i = sessionOrder.firstIndex(where: { !live.contains($0) }) {
                sessionSpots[sessionOrder[i]] = nil
                sessionOrder.remove(at: i)
            }
            saveOrder()
        }
        return sessions.sorted { (sessionOrder.firstIndex(of: $0.id) ?? .max) < (sessionOrder.firstIndex(of: $1.id) ?? .max) }
    }

    /// `id` was found at `spot`: the live sessions whose place is known swap among their own keys
    /// so they read left to right (then top to bottom) as on screen. The others keep theirs.
    private func learn(_ id: String, at spot: CGPoint, live: [String]) {
        sessionSpots[id] = spot
        let known = sessionOrder.indices.filter { live.contains(sessionOrder[$0]) && sessionSpots[sessionOrder[$0]] != nil }
        let sorted = known.map { sessionOrder[$0] }.sorted {
            let a = sessionSpots[$0]!, b = sessionSpots[$1]!
            return abs(a.x - b.x) > 40 ? a.x < b.x : a.y < b.y
        }
        for (slot, session) in zip(known, sorted) { sessionOrder[slot] = session }
        saveOrder()
        redraw()
    }

    private func saveOrder() {
        UserDefaults.standard.set(sessionOrder, forKey: Self.orderKey)
        UserDefaults.standard.set(sessionSpots.mapValues { [Double($0.x), Double($0.y)] }, forKey: Self.spotsKey)
    }

    private func snapshot() -> DeckSnapshot {
        let app = AppState.shared
        var s = DeckSnapshot()
        // The demo is not real: the deck shows none of it.
        if !DemoEngine.shared.isActive {
            // One key per session: several sessions of one client (two `claude` in Ghostty) share a
            // pill, and its card lists them in sessionLines.
            var sessions: [DeckSnapshot.Session] = []
            for task in app.tasks where task.source != .n8n && PillCatalog.isSession(task.id) {
                let project = task.sessionCwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                if task.sessionLines.isEmpty {
                    let step = task.steps.indices.contains(task.stepIndex) ? task.steps[task.stepIndex] : (task.steps.last ?? "")
                    sessions.append(.init(id: Self.deckId(session: task.sessionKey, task: task), agent: task.name, project: project,
                                          state: task.state.rawValue, step: step, color: task.color))
                } else {
                    for line in task.sessionLines {
                        sessions.append(.init(id: Self.deckId(session: line.id, task: task), agent: line.title,
                                              project: line.project ?? project,
                                              state: line.state.rawValue, step: line.lastStep, color: task.color))
                    }
                }
            }
            // Two sessions in one project: the conversation's title tells them apart.
            let names = sessions.map { $0.project ?? $0.agent }
            for i in sessions.indices where names.filter({ $0 == names[i] }).count > 1 && !sessions[i].agent.isEmpty {
                sessions[i].project = sessions[i].agent
            }
            s.sessions = ordered(sessions)
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
            s.planWeek = usage.sevenDay.map(ClaudePlanGauge.effectivePct)
            s.planWeekResets = usage.sevenDay?.resetsAt
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
        s.recordingReady = Parakeet.shared.isReady
        s.page = page
        s.micMuted = DeckAudio.micMuted()
        s.output = DeckAudio.outputName()
        if let end = focusEnd {
            s.timer = .init(remaining: max(0, Int(end.timeIntervalSinceNow.rounded(.up))), total: focusTotal, isBreak: focusIsBreak)
        }
        s.vitals = lastVitals
        s.restTick = Int(Date().timeIntervalSince1970 / 60)
        s.awakeSlot = awakeSlot
        s.overallState = app.effectiveState.rawValue
        s.clock = clockFormat.string(from: Date())
        return s
    }

    // MARK: Drawing

    private func redraw() {
        guard device.isConnected else { return }
        var s = snapshot()
        // Screens turned off with knob 1: a request waiting for the user lights them up again.
        if !screensOn, DeckLayout.requestId(s) != nil {
            screensOn = true
            armClock = DeckArmClock() // the request was not visible: its keys wait from now
            device.send([DeckProtocol.brightness(brightness)])
        }
        guard screensOn else { return }
        // A new request brings the deck back to the agents page, where its sessions are.
        let requestId = DeckLayout.requestId(s)
        if let requestId, requestId != lastRequestId, page != .agents {
            page = .agents
            s.page = .agents
        }
        lastRequestId = requestId
        updateVitalsTimer(on: page == .focus && DeckLayout.mode(s) == .normal && s.timer == nil)
        armClock.update(requestId: requestId, now: Date())
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
        // Spotify open is enough: play/pause works even while its pill (and so its track) is off.
        let spotifyActive = SpotifyController.shared.track != nil || SpotifyController.shared.isRunning
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
            let sessions = snapshot().sessions
            guard let task = Self.task(for: sessionId, in: app.tasks) else { return }
            let session = sessions.first { $0.id == sessionId }
            TerminalJump.jump(to: task, names: [session?.agent, session?.project].compactMap { $0 }) { [weak self] spot in
                guard let self, let spot else { return }
                self.learn(sessionId, at: spot, live: self.snapshot().sessions.map(\.id))
            }
        case .poke(let slot):
            // A free key's Mochi wakes up happy for a moment, then goes back to sleep.
            awakeSlot = slot
            SoundEngine.shared.play("love")
            napWork?.cancel()
            let nap = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.awakeSlot = nil
                self.redraw()
            }
            napWork = nap
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: nap)
            redraw()
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
        case .page(let delta):
            let count = DeckPage.allCases.count
            page = DeckPage(rawValue: ((page.rawValue + delta) % count + count) % count) ?? .agents
            if page == .focus { lastVitals = vitals.sample() } // primes the CPU reading
            redraw()
        case .toggleMic:
            DeckAudio.toggleMic()
            redraw()
        case .nextOutput:
            DeckAudio.nextOutput()
            redraw()
        case .startTimer(let minutes, let isBreak):
            startFocusTimer(seconds: minutes * 60, isBreak: isBreak)
        case .stopTimer:
            stopFocusTimer()
            redraw()
        case .adjustTimer(let minutes):
            guard let end = focusEnd else { return }
            let newEnd = end.addingTimeInterval(TimeInterval(minutes * 60))
            // Never below a minute left; the total grows with it so the bar stays honest.
            guard newEnd.timeIntervalSinceNow >= 60 else { return }
            focusEnd = newEnd
            focusTotal = max(60, focusTotal + minutes * 60)
            redraw()
        case .capture:
            ScreenCapture.shared.begin()
        case .lockScreen:
            DeckLock.now()
        }
    }

    // MARK: Focus timer and vitals

    private func startFocusTimer(seconds: Int, isBreak: Bool) {
        focusEnd = Date().addingTimeInterval(TimeInterval(seconds))
        focusTotal = seconds
        focusIsBreak = isBreak
        secondTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        secondTimer = timer
        redraw()
    }

    private func focusTick() {
        guard let end = focusEnd else { return }
        if end.timeIntervalSinceNow <= 0 {
            stopFocusTimer()
            SoundEngine.shared.play("finish")
        }
        redraw()
    }

    private func stopFocusTimer() {
        secondTimer?.invalidate()
        secondTimer = nil
        focusEnd = nil
    }

    /// CPU, memory and battery are read every 3 s, only while the focus page shows them.
    private func updateVitalsTimer(on: Bool) {
        if !on {
            vitalsTimer?.invalidate()
            vitalsTimer = nil
            return
        }
        guard vitalsTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastVitals = self.vitals.sample()
                self.redraw()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        vitalsTimer = timer
    }
}

#endif

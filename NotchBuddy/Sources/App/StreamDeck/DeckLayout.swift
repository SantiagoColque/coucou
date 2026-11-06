import Foundation

// MARK: - What the stream deck shows, and what each control does
//
// Pure logic, no AppKit: DeckService turns the app state into a DeckSnapshot, this file turns the
// snapshot into one tile per screen and a control event into an action. Tested by
// tests/DeckProtocolTests.swift.
//
// Layout (10 keys, 5 per row, a 4-panel touch strip with a knob under each panel):
//   normal    pages, changed by swiping the strip; the bottom row is the same on every page:
//             key 5 the focus timer (press: 25 min focus, or stop it), key 6 the Mac's microphone, key 7 audio output,
//             key 8 dictation (hold), key 9 record a call.
//             Panel 4 is Mochi, the clock and the page dots on every page.
//     agents  keys 0-4 live agent sessions (press: jump to its terminal); a free key has a Mochi asleep,
//             which a press wakes for a moment
//             strip: weekly plan usage · selected session · music
//     focus   keys 0-4 focus 25 · focus 50 · break 5 · screen capture · lock the screen
//             strip: the timer across panels 1-3 while it runs, otherwise CPU · memory · battery
//   approval  keys 0-4 sessions, key 5 Allow, key 6 Always, key 8 open terminal, key 9 Deny; the strip shows the command.
//             A command too long to read whole on the strip gets no Allow and no Always (as on the Android phone).
//   question  keys 0-7 the options, key 8 answer in the terminal; the strip shows the question
//   A request brings the deck back to the agents page.
//
// A request (approval or question) ignores its keys for `armDelay` after it appears, so a key already
// on its way down when the request lands can never answer it.

#if !APPSTORE

struct DeckSnapshot: Equatable, Sendable {
    struct Session: Equatable, Sendable {
        var id: String
        var agent: String
        var project: String?
        var state: String
        var step: String
        var color: String
    }

    struct Approval: Equatable, Sendable {
        var id: UUID
        var tool: String
        var command: String
        var project: String
        var allowsAlways: Bool
        /// ExitPlanMode has its own answers (auto, manual, keep planning): answered on the Mac.
        var isPlan: Bool
    }

    struct Question: Equatable, Sendable {
        var id: UUID
        var project: String
        var text: String
        /// Empty when the question cannot be answered with one key (several questions, multi-select, too many options).
        var options: [String]
    }

    struct Music: Equatable, Sendable {
        var title: String
        var artist: String
        var playing: Bool
        /// Changes with the track, so the panel is redrawn when the artwork does.
        var artworkKey: String?
    }

    enum Dictation: Equatable, Sendable { case off, idle, listening, thinking }

    struct FocusTimer: Equatable, Sendable {
        var remaining: Int   // seconds
        var total: Int       // seconds
        var isBreak: Bool
    }

    struct Vitals: Equatable, Sendable {
        var cpu: Int         // percent
        var memory: Int      // percent
        var battery: Int?    // percent, nil on a Mac without one
        var charging: Bool
    }

    var sessions: [Session] = []
    var approval: Approval?
    var question: Question?
    /// The weekly limit only: the Max plan has no limit per session.
    var planWeek: Double?
    var planWeekResets: Date?
    var music: Music?
    var dictation: Dictation = .off
    var recordingAvailable = false
    var recording = false
    /// The transcription model the Notetaker needs is downloaded.
    var recordingReady = true
    var page: DeckPage = .agents
    /// nil: no microphone.
    var micMuted: Bool?
    /// The audio output's name; nil when there is none.
    var output: String?
    var timer: FocusTimer?
    var vitals: Vitals?
    /// Changes every minute: the sleeping Mochis on free keys turn over.
    var restTick = 0
    /// The free key whose Mochi was just woken by a press.
    var awakeSlot: Int?
    var overallState = "idle"
    var clock = ""
}

/// The deck's pages, in swipe order.
enum DeckPage: Int, CaseIterable, Equatable, Sendable {
    case agents, focus
}

enum DeckVital: Equatable, Sendable { case cpu, memory, battery }

enum DeckTile: Equatable, Sendable {
    case blank
    // keys
    case session(DeckSnapshot.Session, selected: Bool)
    /// A free session key: a Mochi asleep, or `awake` for a moment after a press.
    case resting(slot: Int, tick: Int, awake: Bool)
    case allow, always, deny
    case option(String)
    case openTerminal
    case dictation(DeckSnapshot.Dictation)
    case record(on: Bool, ready: Bool)
    /// The focus timer on the bottom row, on every page: idle, or running.
    case timerKey(DeckSnapshot.FocusTimer?)
    case mic(muted: Bool)
    case output(String)
    case focusPreset(minutes: Int, isBreak: Bool, active: Bool)
    case capture, lock
    // strip panels
    /// One panel (`part` 0-3) of a request drawn across the strip: the title on panel 0, then this
    /// panel's columns of each text line (see `requestLines`). nil lines: "answer it on the Mac".
    case request(title: String?, lines: [String]?, part: Int)
    case usage(week: Double?, resets: Date?)
    case focus(DeckSnapshot.Session?)
    case music(DeckSnapshot.Music?)
    case mochi(state: String, clock: String, page: Int, pages: Int)
    /// One of panels 0-2 (`part`) of the focus timer drawn across them.
    case timer(DeckSnapshot.FocusTimer, part: Int)
    case vital(DeckVital, value: Int?, charging: Bool)
}

enum DeckAction: Equatable, Sendable {
    case decide(UUID, String)          // "allow", "always" or "deny"
    case answer(UUID, String)          // the option's label
    case answerInTerminal(UUID)
    case jumpToRequest
    case jump(sessionId: String)
    case poke(slot: Int)
    case dictationStart, dictationStop
    case toggleRecording
    case brightness(delta: Int)
    case toggleScreens
    case select(delta: Int)
    case musicPlayPause, musicNext
    case volume(delta: Int)
    case openCoucou
    case page(delta: Int)
    case toggleMic, nextOutput
    case startTimer(minutes: Int, isBreak: Bool)
    case stopTimer
    case adjustTimer(minutes: Int)
    case capture, lockScreen
}

enum DeckLayout {
    /// Session keys: the top row. More sessions are reached with knob 2 and panel 2.
    static let maxSessionKeys = 5
    /// Options of a question: every key but the terminal one's row neighbours.
    static let maxOptionKeys = 8
    static let timerKey = 5, micKey = 6, outputKey = 7
    /// What the timer key starts.
    static let quickFocusMinutes = 25
    static let dictationKey = 8, recordKey = 9
    /// Focus page, top row.
    static let focusPresets: [(minutes: Int, isBreak: Bool)] = [(25, false), (50, false), (5, true)]
    static let captureKey = 3, lockKey = 4
    /// Panels the focus timer spans.
    static let timerPanels = 3
    static let allowKey = 5, alwaysKey = 6, terminalKey = 8, denyKey = 9
    /// Counted from when the deck is sent the request; uploading all 14 screens takes about 0.2 s of it.
    static let armDelay: TimeInterval = 0.8
    /// What the strip shows in full: 4 lines of monospaced text, `panelColumns` characters on each panel.
    static let maxCommandLength = 240, maxCommandLines = 4
    static let panelColumns = 17
    static var lineColumns: Int { panelColumns * DeckProtocol.stripCount }

    /// Allow (and Always) only for a command the strip shows whole.
    static func canAllow(_ a: DeckSnapshot.Approval) -> Bool {
        !a.isPlan && a.command.count <= maxCommandLength && wrap(a.command, words: false).count <= maxCommandLines
    }

    /// Text cut into lines of `lineColumns` characters: a command at any character (nothing is
    /// moved or hidden), a question between words when it can.
    static func wrap(_ text: String, words: Bool) -> [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(raw)
            if rest.isEmpty { lines.append(""); continue }
            while !rest.isEmpty {
                if rest.count <= lineColumns { lines.append(String(rest)); break }
                var cut = rest.index(rest.startIndex, offsetBy: lineColumns)
                if words, let space = rest[..<cut].lastIndex(of: " "), space > rest.startIndex {
                    cut = rest.index(after: space)
                }
                lines.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
        }
        return lines
    }

    /// Panel `part`'s columns of each line: the strip reads as one text, and no character falls
    /// in the gap between two panels.
    static func requestLines(_ lines: [String], part: Int) -> [String] {
        lines.prefix(maxCommandLines).map { line in
            let chars = Array(line)
            let start = part * panelColumns
            guard start < chars.count else { return "" }
            return String(chars[start..<min(chars.count, start + panelColumns)])
        }
    }

    enum Mode: Equatable { case normal, approval, question }

    static func mode(_ s: DeckSnapshot) -> Mode {
        if s.approval != nil { return .approval }
        if s.question != nil { return .question }
        return .normal
    }

    /// The id of the request on the deck, if any: what the arm delay is measured against.
    static func requestId(_ s: DeckSnapshot) -> UUID? { s.approval?.id ?? s.question?.id }

    static func clampedSelection(_ selected: Int, _ s: DeckSnapshot) -> Int {
        let count = s.sessions.count
        return count == 0 ? 0 : max(0, min(count - 1, selected))
    }

    // MARK: Tiles

    static func tiles(_ s: DeckSnapshot, selected: Int) -> [DeckProtocol.Screen: DeckTile] {
        var t: [DeckProtocol.Screen: DeckTile] = [:]
        for screen in DeckProtocol.Screen.all { t[screen] = .blank }
        let sel = clampedSelection(selected, s)

        func sessionKeys() {
            for (i, session) in s.sessions.prefix(maxSessionKeys).enumerated() {
                t[.key(i)] = .session(session, selected: i == sel)
            }
        }

        switch mode(s) {
        case .approval:
            let a = s.approval!
            sessionKeys()
            if canAllow(a) {
                t[.key(allowKey)] = .allow
                if a.allowsAlways { t[.key(alwaysKey)] = .always }
            }
            if !a.isPlan { t[.key(denyKey)] = .deny }
            t[.key(terminalKey)] = .openTerminal
            let title = [a.project, a.tool].filter { !$0.isEmpty }.joined(separator: " · ")
            let lines = wrap(a.command, words: false)
            for i in 0..<DeckProtocol.stripCount {
                t[.strip(i)] = .request(title: i == 0 ? title : nil,
                                        lines: a.isPlan ? nil : requestLines(lines, part: i), part: i)
            }
        case .question:
            let q = s.question!
            for (i, label) in q.options.prefix(maxOptionKeys).enumerated() { t[.key(i)] = .option(label) }
            t[.key(terminalKey)] = .openTerminal
            let lines = wrap(q.text, words: true)
            for i in 0..<DeckProtocol.stripCount {
                t[.strip(i)] = .request(title: i == 0 ? q.project : nil, lines: requestLines(lines, part: i), part: i)
            }
        case .normal:
            switch s.page {
            case .agents:
                sessionKeys()
                for i in min(s.sessions.count, maxSessionKeys)..<maxSessionKeys {
                    t[.key(i)] = .resting(slot: i, tick: s.restTick, awake: s.awakeSlot == i)
                }
                t[.strip(0)] = .usage(week: s.planWeek, resets: s.planWeekResets)
                t[.strip(1)] = .focus(s.sessions.indices.contains(sel) ? s.sessions[sel] : nil)
                t[.strip(2)] = .music(s.music)
            case .focus:
                for (i, p) in focusPresets.enumerated() {
                    let active = s.timer.map { $0.total == p.minutes * 60 && $0.isBreak == p.isBreak } ?? false
                    t[.key(i)] = .focusPreset(minutes: p.minutes, isBreak: p.isBreak, active: active)
                }
                t[.key(captureKey)] = .capture
                t[.key(lockKey)] = .lock
                if let timer = s.timer {
                    for i in 0..<timerPanels { t[.strip(i)] = .timer(timer, part: i) }
                } else {
                    let v = s.vitals
                    t[.strip(0)] = .vital(.cpu, value: v?.cpu, charging: false)
                    t[.strip(1)] = .vital(.memory, value: v?.memory, charging: false)
                    t[.strip(2)] = .vital(.battery, value: v?.battery, charging: v?.charging ?? false)
                }
            }
            t[.key(timerKey)] = .timerKey(s.timer)
            if let muted = s.micMuted { t[.key(micKey)] = .mic(muted: muted) }
            if let output = s.output { t[.key(outputKey)] = .output(output) }
            t[.key(dictationKey)] = .dictation(s.dictation)
            if s.recordingAvailable { t[.key(recordKey)] = .record(on: s.recording, ready: s.recordingReady) }
            t[.strip(3)] = .mochi(state: s.overallState, clock: s.clock, page: s.page.rawValue, pages: DeckPage.allCases.count)
        }
        return t
    }

    // MARK: Actions

    /// `armed`: the request on the deck has been there for at least `armDelay`.
    static func action(for event: DeckProtocol.Event, _ s: DeckSnapshot, selected: Int, armed: Bool) -> DeckAction? {
        // Releasing the dictation key always ends a dictation, whatever appeared on the deck meanwhile.
        if case .keyUp(dictationKey) = event, s.dictation == .listening { return .dictationStop }
        let sel = clampedSelection(selected, s)

        switch event {
        case .keyUp:
            return nil // keys act on the way down

        case .swipe(let left):
            // A request keeps the agents page; otherwise the finger drags the next page in.
            guard mode(s) == .normal else { return nil }
            return .page(delta: left ? 1 : -1)

        case .keyDown(let k):
            switch mode(s) {
            case .approval:
                let a = s.approval!
                if k < 5 { return jump(k, s) }
                // Key 8 is the dictation key in the normal layout: it waits like the others.
                guard armed else { return nil }
                if k == terminalKey { return .jumpToRequest }
                guard !a.isPlan else { return nil }
                if k == denyKey { return .decide(a.id, "deny") }
                guard canAllow(a) else { return nil }
                if k == allowKey { return .decide(a.id, "allow") }
                if k == alwaysKey, a.allowsAlways { return .decide(a.id, "always") }
                return nil
            case .question:
                let q = s.question!
                guard armed else { return nil }
                if k == terminalKey { return .answerInTerminal(q.id) }
                guard k < min(q.options.count, maxOptionKeys) else { return nil }
                return .answer(q.id, q.options[k])
            case .normal:
                if k < 5 {
                    switch s.page {
                    case .agents: return s.sessions.indices.contains(k) ? jump(k, s) : .poke(slot: k)
                    case .focus:
                        if k == captureKey { return .capture }
                        if k == lockKey { return .lockScreen }
                        let p = focusPresets[k]
                        let active = s.timer.map { $0.total == p.minutes * 60 && $0.isBreak == p.isBreak } ?? false
                        return active ? .stopTimer : .startTimer(minutes: p.minutes, isBreak: p.isBreak)
                    }
                }
                if k == timerKey {
                    return s.timer == nil ? .startTimer(minutes: quickFocusMinutes, isBreak: false) : .stopTimer
                }
                if k == micKey { return s.micMuted == nil ? nil : .toggleMic }
                if k == outputKey { return s.output == nil ? nil : .nextOutput }
                if k == dictationKey {
                    switch s.dictation {
                    case .idle: return .dictationStart
                    case .listening: return .dictationStop // started elsewhere: the key ends it
                    case .off, .thinking: return nil
                    }
                }
                if k == recordKey, s.recordingAvailable { return .toggleRecording }
                return nil
            }

        case .knobTurn(let knob, let steps):
            switch knob {
            case 0: return .brightness(delta: steps * 10)
            case 1: return .select(delta: steps)
            case 2: return .volume(delta: steps * 4)
            default: return s.timer == nil ? nil : .adjustTimer(minutes: steps)
            }

        case .knobPress(let knob):
            if knob == 3, s.timer != nil { return .stopTimer }
            return panelAction(knob, s, sel)

        case .stripTap(let panel):
            // In a request the strip is the request's text: a tap there does nothing.
            guard mode(s) == .normal else { return nil }
            if s.page == .focus { return panel == 3 ? .openCoucou : nil }
            return panel == 2 ? .musicNext : panelAction(panel, s, sel)
        }
    }

    private static func panelAction(_ panel: Int, _ s: DeckSnapshot, _ sel: Int) -> DeckAction? {
        switch panel {
        case 0: return .toggleScreens
        case 1: return s.sessions.indices.contains(sel) ? .jump(sessionId: s.sessions[sel].id) : nil
        case 2: return .musicPlayPause
        default: return .openCoucou
        }
    }

    private static func jump(_ k: Int, _ s: DeckSnapshot) -> DeckAction? {
        s.sessions.indices.contains(k) ? .jump(sessionId: s.sessions[k].id) : nil
    }
}

// MARK: - Arm delay

/// When the request on the deck appeared, so its keys wait `armDelay` before they answer it.
struct DeckArmClock: Sendable {
    private(set) var requestId: UUID?
    private(set) var shownAt = Date.distantPast

    /// Call when the deck is drawn and before acting on a key: a new request restarts the clock.
    mutating func update(requestId: UUID?, now: Date) {
        guard requestId != self.requestId else { return }
        self.requestId = requestId
        shownAt = now
    }

    /// Updates for `requestId`, then tells whether that request has been shown long enough.
    mutating func armed(for requestId: UUID?, now: Date) -> Bool {
        update(requestId: requestId, now: now)
        return requestId != nil && now.timeIntervalSince(shownAt) >= DeckLayout.armDelay
    }
}

#endif

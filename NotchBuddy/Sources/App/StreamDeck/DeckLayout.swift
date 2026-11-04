import Foundation

// MARK: - What the stream deck shows, and what each control does
//
// Pure logic, no AppKit: DeckService turns the app state into a DeckSnapshot, this file turns the
// snapshot into one tile per screen and a control event into an action. Tested by
// tests/DeckProtocolTests.swift.
//
// Layout (10 keys, 5 per row, a 4-panel touch strip with a knob under each panel):
//   normal    keys 0-7 live agent sessions (press: jump to its terminal), key 8 dictation (hold), key 9 record a call
//             strip: plan usage · selected session · music · Mochi + clock
//   approval  keys 0-4 sessions, key 5 Allow, key 6 Always, key 8 open terminal, key 9 Deny; the strip shows the command.
//             A command too long to read whole on the strip gets no Allow and no Always (as on the Android phone).
//   question  keys 0-7 the options, key 8 answer in the terminal; the strip shows the question
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

    var sessions: [Session] = []
    var approval: Approval?
    var question: Question?
    var planFiveHour: Double?
    var planWeek: Double?
    var music: Music?
    var dictation: Dictation = .off
    var recordingAvailable = false
    var recording = false
    var overallState = "idle"
    var clock = ""
}

enum DeckTile: Equatable, Sendable {
    case blank
    // keys
    case session(DeckSnapshot.Session, selected: Bool)
    case allow, always, deny
    case option(String)
    case openTerminal
    case dictation(DeckSnapshot.Dictation)
    case record(on: Bool)
    // strip panels
    /// One quarter (`part` 0-3) of a request drawn across the whole strip. nil body: "answer it on the Mac".
    case request(title: String, body: String?, part: Int)
    case usage(fiveHour: Double?, week: Double?)
    case focus(DeckSnapshot.Session?)
    case music(DeckSnapshot.Music?)
    case mochi(state: String, clock: String)
}

enum DeckAction: Equatable, Sendable {
    case decide(UUID, String)          // "allow", "always" or "deny"
    case answer(UUID, String)          // the option's label
    case answerInTerminal(UUID)
    case jumpToRequest
    case jump(sessionId: String)
    case dictationStart, dictationStop
    case toggleRecording
    case brightness(delta: Int)
    case toggleScreens
    case select(delta: Int)
    case musicPlayPause, musicNext
    case volume(delta: Int)
    case openCoucou
}

enum DeckLayout {
    static let maxSessionKeys = 8
    static let dictationKey = 8, recordKey = 9
    static let allowKey = 5, alwaysKey = 6, terminalKey = 8, denyKey = 9
    /// Counted from when the deck is sent the request; uploading all 14 screens takes about 0.2 s of it.
    static let armDelay: TimeInterval = 0.8
    /// What the strip shows in full (4 lines of monospaced text across 704 px).
    static let maxCommandLength = 240, maxCommandLines = 4

    /// Allow (and Always) only for a command the strip shows whole.
    static func canAllow(_ a: DeckSnapshot.Approval) -> Bool {
        !a.isPlan && a.command.count <= maxCommandLength
            && a.command.split(separator: "\n", omittingEmptySubsequences: false).count <= maxCommandLines
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
        let count = min(s.sessions.count, maxSessionKeys)
        return count == 0 ? 0 : max(0, min(count - 1, selected))
    }

    // MARK: Tiles

    static func tiles(_ s: DeckSnapshot, selected: Int) -> [DeckProtocol.Screen: DeckTile] {
        var t: [DeckProtocol.Screen: DeckTile] = [:]
        for screen in DeckProtocol.Screen.all { t[screen] = .blank }
        let sel = clampedSelection(selected, s)

        func sessionKeys(_ count: Int) {
            for (i, session) in s.sessions.prefix(count).enumerated() {
                t[.key(i)] = .session(session, selected: i == sel)
            }
        }

        switch mode(s) {
        case .approval:
            let a = s.approval!
            sessionKeys(5)
            if canAllow(a) {
                t[.key(allowKey)] = .allow
                if a.allowsAlways { t[.key(alwaysKey)] = .always }
            }
            if !a.isPlan { t[.key(denyKey)] = .deny }
            t[.key(terminalKey)] = .openTerminal
            let body: String? = a.isPlan ? nil : a.command
            for i in 0..<DeckProtocol.stripCount {
                t[.strip(i)] = .request(title: [a.project, a.tool].filter { !$0.isEmpty }.joined(separator: " · "), body: body, part: i)
            }
        case .question:
            let q = s.question!
            for (i, label) in q.options.prefix(maxSessionKeys).enumerated() { t[.key(i)] = .option(label) }
            t[.key(terminalKey)] = .openTerminal
            for i in 0..<DeckProtocol.stripCount {
                t[.strip(i)] = .request(title: q.project, body: q.text, part: i)
            }
        case .normal:
            sessionKeys(maxSessionKeys)
            t[.key(dictationKey)] = .dictation(s.dictation)
            if s.recordingAvailable { t[.key(recordKey)] = .record(on: s.recording) }
            t[.strip(0)] = .usage(fiveHour: s.planFiveHour, week: s.planWeek)
            t[.strip(1)] = .focus(s.sessions.indices.contains(sel) ? s.sessions[sel] : nil)
            t[.strip(2)] = .music(s.music)
            t[.strip(3)] = .mochi(state: s.overallState, clock: s.clock)
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
        case .keyUp, .swipe:
            return nil // swipes are unreliable on this hardware (opendeck-akp05); keys act on the way down

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
                guard k < min(q.options.count, maxSessionKeys) else { return nil }
                return .answer(q.id, q.options[k])
            case .normal:
                if k < maxSessionKeys { return jump(k, s) }
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
            default: return nil
            }

        case .knobPress(let knob):
            return panelAction(knob, s, sel)

        case .stripTap(let panel):
            // In a request the strip is the request's text: a tap there does nothing.
            guard mode(s) == .normal else { return nil }
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

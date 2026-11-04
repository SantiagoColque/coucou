import Foundation

// Stream deck wire protocol and layout (NotchBuddy/Sources/App/StreamDeck/DeckProtocol.swift, DeckLayout.swift).
// Run: bash scripts/test-deck-protocol.sh

@main
enum DeckProtocolTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }

    static func report(_ code: UInt8, _ state: UInt8 = 1) -> [UInt8] {
        var r = Array("ACK".utf8) + [0, 0] + Array("OK".utf8) + [0, 0, code, state]
        r += [UInt8](repeating: 0, count: 512 - r.count)
        return r
    }

    static func session(_ id: String) -> DeckSnapshot.Session {
        .init(id: id, agent: "Claude Code", project: id, state: "working", step: "Edit", color: "#D97757")
    }

    static func main() {
        print("DeckProtocol.command")
        let lig = DeckProtocol.brightness(80)
        check("1024 bytes", lig.count, 1024)
        check("CRT header + LIG + 0 0 80", Array(lig.prefix(11)), Array("CRT".utf8) + [0, 0] + Array("LIG".utf8) + [0, 0, 80])
        check("brightness is clamped", DeckProtocol.brightness(250)[10], 100)
        check("padding is zero", lig.dropFirst(11).allSatisfy { $0 == 0 }, true)

        print("DeckProtocol.Screen (measured on the SS552)")
        check("top-left key is slot 11", DeckProtocol.Screen.key(0).wireSlot, 11)
        check("top-right key is slot 15", DeckProtocol.Screen.key(4).wireSlot, 15)
        check("bottom-left key is slot 6", DeckProtocol.Screen.key(5).wireSlot, 6)
        check("bottom-right key is slot 10", DeckProtocol.Screen.key(9).wireSlot, 10)
        check("strip panels are slots 1-4", (0..<4).map { DeckProtocol.Screen.strip($0).wireSlot }, [1, 2, 3, 4])
        check("14 screens", Set(DeckProtocol.Screen.all.map(\.wireSlot)).count, 14)

        print("DeckProtocol.image")
        let jpeg = (0..<2500).map { UInt8($0 % 251) }
        let reports = DeckProtocol.image(jpeg, on: .key(0))
        check("header + 3 chunks", reports.count, 4)
        check("BAT header with length and slot", Array(reports[0].prefix(13)),
              Array("CRT".utf8) + [0, 0] + Array("BAT".utf8) + [0, 0, 0x09, 0xC4, 11])
        check("every report is 1024 bytes", reports.allSatisfy { $0.count == 1024 }, true)
        check("chunks carry the bytes in order", Array(reports[1...].joined().prefix(2500)), jpeg)
        check("last chunk is zero padded", reports[3].dropFirst(2500 - 2048).allSatisfy { $0 == 0 }, true)

        check("oversized JPEG is refused", DeckProtocol.image([UInt8](repeating: 0, count: 0x10000), on: .key(0)).count, 0)

        print("DeckProtocol.parse")
        check("key 10 down (seen on the SS552)", DeckProtocol.parse(report(0x0A, 1)), .keyDown(9))
        check("key 10 up (seen on the SS552)", DeckProtocol.parse(report(0x0A, 0)), .keyUp(9))
        check("key 1 down", DeckProtocol.parse(report(0x01)), .keyDown(0))
        check("knob 1 counter-clockwise", DeckProtocol.parse(report(0xA0)), .knobTurn(knob: 0, steps: -1))
        check("knob 4 clockwise", DeckProtocol.parse(report(0x71)), .knobTurn(knob: 3, steps: 1))
        check("knob 3 press", DeckProtocol.parse(report(0x33)), .knobPress(2))
        check("strip tap 2", DeckProtocol.parse(report(0x41)), .stripTap(1))
        check("not an ACK", DeckProtocol.parse([0x41, 0x42] + [UInt8](repeating: 0, count: 20)), nil)
        check("unknown code", DeckProtocol.parse(report(0xEE)), nil)
        check("short report", DeckProtocol.parse([0x41, 0x43, 0x4B]), nil)

        print("DeckLayout.tiles")
        var s = DeckSnapshot()
        s.sessions = (0..<10).map { session("p\($0)") }
        s.dictation = .idle
        s.recordingAvailable = true
        var t = DeckLayout.tiles(s, selected: 1)
        check("5 session keys, the top row", t[.key(4)], .session(session("p4"), selected: false))
        check("no resting key while sessions fill the row", t[.key(3)], .session(session("p3"), selected: false))
        check("key 5 is the meeting, not a session", t[.key(5)], .meeting(nil, access: .notAsked))
        check("selected session is marked", t[.key(1)], .session(session("p1"), selected: true))
        check("key 8 dictation", t[.key(8)], .dictation(.idle))
        check("key 9 record", t[.key(9)], .record(on: false, ready: true))
        check("no mic key without a microphone", t[.key(6)], .blank)
        check("panel 4: Mochi with the page dots", t[.strip(3)], .mochi(state: "idle", clock: "", page: 0, pages: DeckPage.allCases.count))
        check("panel 2 shows the selected session", t[.strip(1)], .focus(session("p1")))
        s.recordingAvailable = false
        check("no record key without the Notetaker", DeckLayout.tiles(s, selected: 0)[.key(9)], .blank)

        let approvalId = UUID()
        s.approval = .init(id: approvalId, tool: "Bash", command: "rm -rf build", project: "coucou", allowsAlways: true, isPlan: false)
        t = DeckLayout.tiles(s, selected: 0)
        check("approval: allow on key 5", t[.key(5)], .allow)
        check("approval: always on key 6", t[.key(6)], .always)
        check("approval: deny on key 9, far from allow", t[.key(9)], .deny)
        check("approval: key 8 opens the terminal", t[.key(8)], .openTerminal)
        check("approval: title on panel 1", t[.strip(0)], .request(title: "coucou · Bash", lines: ["rm -rf build"], part: 0))
        check("approval: a short command stays on panel 1", t[.strip(2)], .request(title: nil, lines: [""], part: 2))
        check("approval: sessions stay on the top row", t[.key(4)], .session(session("p4"), selected: false))
        s.approval!.allowsAlways = false
        check("no Always for Codex", DeckLayout.tiles(s, selected: 0)[.key(6)], .blank)
        s.approval!.isPlan = true
        t = DeckLayout.tiles(s, selected: 0)
        check("plan: no Allow key", t[.key(5)], .blank)
        check("plan: no Deny key", t[.key(9)], .blank)
        check("plan: strip says answer on the Mac", t[.strip(0)], .request(title: "coucou · Bash", lines: nil, part: 0))

        print("DeckLayout.action (approval)")
        s.approval!.isPlan = false
        s.approval!.allowsAlways = true
        check("allow when armed", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), .decide(approvalId, "allow"))
        check("allow ignored before the arm delay", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: false), nil)
        check("deny ignored before the arm delay", DeckLayout.action(for: .keyDown(9), s, selected: 0, armed: false), nil)
        check("deny when armed", DeckLayout.action(for: .keyDown(9), s, selected: 0, armed: true), .decide(approvalId, "deny"))
        check("always when armed", DeckLayout.action(for: .keyDown(6), s, selected: 0, armed: true), .decide(approvalId, "always"))
        check("key up never decides", DeckLayout.action(for: .keyUp(5), s, selected: 0, armed: true), nil)
        check("empty key 7 does nothing", DeckLayout.action(for: .keyDown(7), s, selected: 0, armed: true), nil)
        check("terminal key waits for the arm delay", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: false), nil)
        check("terminal key when armed", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: true), .jumpToRequest)
        check("session keys work unarmed", DeckLayout.action(for: .keyDown(2), s, selected: 0, armed: false), .jump(sessionId: "p2"))
        check("strip tap does nothing in a request", DeckLayout.action(for: .stripTap(0), s, selected: 0, armed: true), nil)
        s.approval!.allowsAlways = false
        check("no always for Codex", DeckLayout.action(for: .keyDown(6), s, selected: 0, armed: true), nil)
        s.approval!.isPlan = true
        check("plan: allow key does nothing", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), nil)
        s.approval!.isPlan = false
        s.approval!.allowsAlways = true
        s.approval!.command = String(repeating: "x", count: DeckLayout.maxCommandLength + 1)
        t = DeckLayout.tiles(s, selected: 0)
        check("long command: no Allow key", t[.key(5)], .blank)
        check("long command: no Always key", t[.key(6)], .blank)
        check("long command: Deny stays", t[.key(9)], .deny)
        check("long command: allow does nothing", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), nil)
        check("long command: always does nothing", DeckLayout.action(for: .keyDown(6), s, selected: 0, armed: true), nil)
        check("long command: deny works", DeckLayout.action(for: .keyDown(9), s, selected: 0, armed: true), .decide(approvalId, "deny"))
        s.approval!.command = "a\nb\nc\nd\ne"
        check("five-line command: no Allow", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), nil)
        s.approval!.command = "a\nb\nc\nd"
        check("four-line command: Allow", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), .decide(approvalId, "allow"))
        s.approval!.command = String(repeating: "y", count: 100) + "\nb\nc\nd"
        check("three lines that wrap to five: no Allow", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: true), nil)
        let wide = String((0..<DeckLayout.lineColumns).map { Character(UnicodeScalar(65 + $0 % 26)!) })
        s.approval!.command = wide
        let panels = (0..<4).map { DeckLayout.tiles(s, selected: 0)[.strip($0)] }
        let shown = panels.map { tile -> String in
            if case .request(_, let lines?, _) = tile { return lines.joined() } else { return "?" }
        }.joined()
        check("a full line is split across the panels, every character shown once", shown, wide)
        check("a command wraps at any character", DeckLayout.wrap(String(repeating: "x", count: DeckLayout.lineColumns + 3), words: false).map(\.count), [DeckLayout.lineColumns, 3])
        check("a question wraps between words", DeckLayout.wrap(String(repeating: "ab ", count: 30), words: true).first?.hasSuffix(" "), true)
        s.approval = nil

        print("DeckLayout (question)")
        let questionId = UUID()
        s.question = .init(id: questionId, project: "coucou", text: "Which DB?", options: ["Postgres", "SQLite"])
        t = DeckLayout.tiles(s, selected: 0)
        check("options on the keys", t[.key(1)], .option("SQLite"))
        check("no session keys during a question", t[.key(2)], .blank)
        check("answer when armed", DeckLayout.action(for: .keyDown(1), s, selected: 0, armed: true), .answer(questionId, "SQLite"))
        check("answer ignored before the arm delay", DeckLayout.action(for: .keyDown(0), s, selected: 0, armed: false), nil)
        check("key past the options does nothing", DeckLayout.action(for: .keyDown(3), s, selected: 0, armed: true), nil)
        check("answer in the terminal waits for the arm delay", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: false), nil)
        check("answer in the terminal", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: true), .answerInTerminal(questionId))
        s.question!.options = []
        check("unanswerable question: no option keys", DeckLayout.tiles(s, selected: 0)[.key(0)], .blank)
        check("unanswerable question: keys do nothing", DeckLayout.action(for: .keyDown(0), s, selected: 0, armed: true), nil)
        s.question = nil

        print("DeckLayout.action (normal)")
        check("session key jumps", DeckLayout.action(for: .keyDown(3), s, selected: 0, armed: false), .jump(sessionId: "p3"))
        check("dictation starts on key down", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: false), .dictationStart)
        s.dictation = .listening
        check("dictation stops on key up", DeckLayout.action(for: .keyUp(8), s, selected: 0, armed: false), .dictationStop)
        s.approval = .init(id: approvalId, tool: "Bash", command: "ls", project: "", allowsAlways: true, isPlan: false)
        check("dictation stops on key up even if a request appeared", DeckLayout.action(for: .keyUp(8), s, selected: 0, armed: true), .dictationStop)
        s.approval = nil
        s.dictation = .off
        check("dictation off: key does nothing", DeckLayout.action(for: .keyDown(8), s, selected: 0, armed: false), nil)
        check("knob 2 selects", DeckLayout.action(for: .knobTurn(knob: 1, steps: -1), s, selected: 0, armed: false), .select(delta: -1))
        check("knob 2 press jumps to the selected session", DeckLayout.action(for: .knobPress(1), s, selected: 4, armed: false), .jump(sessionId: "p4"))
        check("selection reaches sessions past the keys", DeckLayout.action(for: .knobPress(1), s, selected: 99, armed: false), .jump(sessionId: "p9"))
        check("a session past the keys is shown on panel 2", DeckLayout.tiles(s, selected: 7)[.strip(1)], .focus(session("p7")))
        check("knob 3 volume", DeckLayout.action(for: .knobTurn(knob: 2, steps: 1), s, selected: 0, armed: false), .volume(delta: 4))
        check("knob 3 press play/pause", DeckLayout.action(for: .knobPress(2), s, selected: 0, armed: false), .musicPlayPause)
        check("music panel tap: next track", DeckLayout.action(for: .stripTap(2), s, selected: 0, armed: false), .musicNext)
        check("knob 1 brightness", DeckLayout.action(for: .knobTurn(knob: 0, steps: -1), s, selected: 0, armed: false), .brightness(delta: -10))
        check("0x38 is a left-to-right swipe", DeckProtocol.parse(Array("ACK".utf8) + [0, 0, 0x4f, 0x4b, 0, 0, 0x38, 0]), .swipe(left: false))
        check("swipe right to left: next page", DeckLayout.action(for: .swipe(left: true), s, selected: 0, armed: false), .page(delta: 1))
        check("swipe left to right: previous page", DeckLayout.action(for: .swipe(left: false), s, selected: 0, armed: false), .page(delta: -1))
        check("knob 4 turn does nothing without a timer", DeckLayout.action(for: .knobTurn(knob: 3, steps: 1), s, selected: 0, armed: false), nil)
        check("meeting key asks for the calendar", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: false), .askCalendar)
        s.calendar = .granted
        check("meeting without a link does nothing", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: false), nil)
        s.meeting = .init(title: "Daily", minutes: 3, start: "10:00", hasLink: true)
        check("meeting key joins", DeckLayout.action(for: .keyDown(5), s, selected: 0, armed: false), .openMeeting)
        check("mic key without a microphone does nothing", DeckLayout.action(for: .keyDown(6), s, selected: 0, armed: false), nil)
        s.micMuted = false
        s.output = "MacBook Pro Speakers"
        check("mic key toggles", DeckLayout.action(for: .keyDown(6), s, selected: 0, armed: false), .toggleMic)
        check("output key switches", DeckLayout.action(for: .keyDown(7), s, selected: 0, armed: false), .nextOutput)
        check("output key shows the device", DeckLayout.tiles(s, selected: 0)[.key(7)], .output("MacBook Pro Speakers"))
        let request = UUID()
        s.approval = .init(id: request, tool: "Bash", command: "ls", project: "", allowsAlways: true, isPlan: false)
        check("no page change during a request", DeckLayout.action(for: .swipe(left: true), s, selected: 0, armed: true), nil)
        check("request: key 7 is empty, not the output", DeckLayout.tiles(s, selected: 0)[.key(7)], .blank)
        s.approval = nil

        print("DeckLayout (focus page)")
        s.page = .focus
        t = DeckLayout.tiles(s, selected: 0)
        check("focus 25 on key 1", t[.key(0)], .focusPreset(minutes: 25, isBreak: false, active: false))
        check("break on key 3", t[.key(2)], .focusPreset(minutes: 5, isBreak: true, active: false))
        check("capture on key 4", t[.key(3)], .capture)
        check("lock on key 5", t[.key(4)], .lock)
        check("bottom row stays", t[.key(6)], .mic(muted: false))
        check("no timer: CPU on panel 1", t[.strip(0)], .vital(.cpu, value: nil, charging: false))
        check("panel 4 dots on page 2", t[.strip(3)], .mochi(state: "idle", clock: "", page: 1, pages: DeckPage.allCases.count))
        check("preset starts a timer", DeckLayout.action(for: .keyDown(1), s, selected: 0, armed: false), .startTimer(minutes: 50, isBreak: false))
        check("capture key", DeckLayout.action(for: .keyDown(3), s, selected: 0, armed: false), .capture)
        check("lock key", DeckLayout.action(for: .keyDown(4), s, selected: 0, armed: false), .lockScreen)
        check("strip tap does nothing on the focus page", DeckLayout.action(for: .stripTap(0), s, selected: 0, armed: false), nil)
        s.timer = .init(remaining: 600, total: 1500, isBreak: false)
        t = DeckLayout.tiles(s, selected: 0)
        check("running preset is marked", t[.key(0)], .focusPreset(minutes: 25, isBreak: false, active: true))
        check("timer across panels 1-3", t[.strip(2)], .timer(s.timer!, part: 2))
        check("running preset stops", DeckLayout.action(for: .keyDown(0), s, selected: 0, armed: false), .stopTimer)
        check("knob 4 adjusts the timer", DeckLayout.action(for: .knobTurn(knob: 3, steps: -1), s, selected: 0, armed: false), .adjustTimer(minutes: -1))
        check("knob 4 press stops the timer", DeckLayout.action(for: .knobPress(3), s, selected: 0, armed: false), .stopTimer)
        s.approval = .init(id: request, tool: "Bash", command: "ls", project: "", allowsAlways: true, isPlan: false)
        check("request on the focus page: sessions on the top row", DeckLayout.tiles(s, selected: 0)[.key(0)], .session(session("p0"), selected: true))
        check("request on the focus page: session keys jump", DeckLayout.action(for: .keyDown(1), s, selected: 0, armed: false), .jump(sessionId: "p1"))
        s.approval = nil
        s.timer = nil
        s.page = .agents
        s.meeting = nil
        s.micMuted = nil
        s.output = nil
        s.calendar = .notAsked
        s.sessions = []
        check("no sessions: a free key wakes its Mochi", DeckLayout.action(for: .keyDown(0), s, selected: 0, armed: false), .poke(slot: 0))
        check("no sessions: free keys rest", DeckLayout.tiles(s, selected: 0)[.key(4)], .resting(slot: 4, tick: 0, awake: false))
        s.awakeSlot = 2
        s.restTick = 7
        check("the poked Mochi is awake", DeckLayout.tiles(s, selected: 0)[.key(2)], .resting(slot: 2, tick: 7, awake: true))
        s.awakeSlot = nil
        s.restTick = 0
        check("no sessions: knob 2 press does nothing", DeckLayout.action(for: .knobPress(1), s, selected: 0, armed: false), nil)

        print("DeckArmClock")
        var clock = DeckArmClock()
        let t0 = Date()
        let a = UUID(), b = UUID()
        check("nothing to arm", clock.armed(for: nil, now: t0), false)
        check("new request is not armed", clock.armed(for: a, now: t0), false)
        check("still not armed just before the delay", clock.armed(for: a, now: t0 + DeckLayout.armDelay - 0.05), false)
        check("armed after the delay", clock.armed(for: a, now: t0 + DeckLayout.armDelay + 0.01), true)
        check("another request restarts the clock", clock.armed(for: b, now: t0 + 5), false)
        check("…and arms after the delay", clock.armed(for: b, now: t0 + 5 + DeckLayout.armDelay + 0.01), true)

        print(failures == 0 ? "\nAll deck tests passed" : "\n\(failures) deck test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

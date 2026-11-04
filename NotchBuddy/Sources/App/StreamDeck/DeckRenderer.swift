import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drawing the deck's screens
//
// Each tile is a small SwiftUI view rendered once with ImageRenderer (scale 1: one point is one
// pixel of the deck's LCD), turned 180° (the panels are mounted upside down) and encoded as JPEG.
// A request spans the whole touch strip: drawn once 704 px wide, each panel gets its quarter.

#if !APPSTORE

@MainActor
enum DeckRenderer {
    static func jpeg(_ tile: DeckTile, on screen: DeckProtocol.Screen, artwork: NSImage?) -> [UInt8]? {
        let isStrip: Bool
        if case .strip = screen { isStrip = true } else { isStrip = false }
        let size = isStrip ? DeckProtocol.stripSize : DeckProtocol.keySize

        if case .timer(let timer, let part) = tile {
            // Drawn once across the panels and their gaps; each panel takes its own piece.
            let pitch = size.width + DeckProtocol.stripGap
            guard let image = timerImage(timer),
                  let piece = image.cropping(to: CGRect(x: part * pitch, y: 0, width: size.width, height: size.height))
            else { return nil }
            return encode(piece)
        }
        let view = DeckTileView(tile: tile, artwork: artwork)
        guard let image = render(view, size: CGSize(width: size.width, height: size.height)) else { return nil }
        return encode(image)
    }

    /// The last timer drawn: its three panels come from one render.
    private static var lastTimer: (timer: DeckSnapshot.FocusTimer, image: CGImage)?

    private static func timerImage(_ timer: DeckSnapshot.FocusTimer) -> CGImage? {
        if let last = lastTimer, last.timer == timer { return last.image }
        let n = DeckLayout.timerPanels
        let size = CGSize(width: DeckProtocol.stripSize.width * n + DeckProtocol.stripGap * (n - 1), height: DeckProtocol.stripSize.height)
        guard let image = render(DeckTimerPanel(timer: timer), size: size) else { return nil }
        lastTimer = (timer, image)
        return image
    }

    private static func render(_ view: some View, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// Turned 180° and encoded as a baseline JPEG, which is what the deck decodes.
    private static func encode(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
        ctx.rotate(by: .pi)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let turned = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, turned, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }
}

// MARK: - Tiles

private var deckOrange: Color { Color(hex: "#F59E0B") }
private var deckGreen: Color { Color(hex: "#22C55E") }
private var deckRed: Color { Color(hex: "#F4505E") }
private var deckBlue: Color { Color(hex: "#3B82F6") }
private var deckGrey: Color { Color(white: 0.55) }

private func botState(_ raw: String) -> BotState { BotState(rawValue: raw) ?? .idle }

/// A session's state in one word, readable on a key.
private func deckStateLabel(_ raw: String) -> String {
    switch botState(raw) {
    case .working, .thinking, .searching: String(localized: "deck.state.working")
    case .approval, .question: String(localized: "deck.state.waiting")
    case .finished: String(localized: "deck.state.done")
    case .error, .ratelimit, .dizzy: String(localized: "deck.state.error")
    case .idle, .sleeping: String(localized: "deck.state.idle")
    }
}

private func deckStateColor(_ raw: String) -> String {
    switch botState(raw) {
    case .working, .thinking, .searching: "#3B82F6"
    case .approval, .question: "#F59E0B"
    case .finished: "#22C55E"
    case .error, .ratelimit, .dizzy: "#F4505E"
    case .idle, .sleeping: "#8C8C8C"
    }
}

private struct DeckTileView: View {
    let tile: DeckTile
    let artwork: NSImage?

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch tile {
        case .blank, .timer:
            EmptyView()
        case .request(let title, let lines, _):
            DeckRequestPanel(title: title, lines: lines)
        case .session(let s, let selected):
            DeckSessionKey(session: s, selected: selected)
        case .allow:
            DeckButtonKey(symbol: "checkmark", title: String(localized: "deck.allow"), color: deckGreen)
        case .always:
            DeckButtonKey(symbol: "checkmark.seal", title: String(localized: "deck.always"), color: deckBlue)
        case .deny:
            DeckButtonKey(symbol: "xmark", title: String(localized: "deck.deny"), color: deckRed)
        case .openTerminal:
            DeckButtonKey(symbol: "terminal", title: String(localized: "deck.terminal"), color: deckGrey, filled: false)
        case .option(let label):
            Text(label)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(4)
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(deckBlue.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(deckBlue, lineWidth: 3))
                .padding(4)
        case .dictation(let d):
            switch d {
            case .off: DeckButtonKey(symbol: "mic.slash", title: String(localized: "deck.dictation.off"), color: deckGrey, filled: false)
            case .idle: DeckButtonKey(symbol: "waveform", title: String(localized: "deck.dictation.hold"), color: deckGrey, filled: false)
            case .listening: DeckButtonKey(symbol: "mic.fill", title: String(localized: "deck.dictation.listening"), color: deckRed)
            case .thinking: DeckButtonKey(symbol: "ellipsis", title: "…", color: deckOrange)
            }
        case .record(let on, let ready):
            if !on && !ready {
                // The Notetaker's transcription model is not downloaded: a press opens where to get it.
                DeckButtonKey(symbol: "arrow.down.circle", title: String(localized: "deck.record.models"), color: deckOrange, filled: false)
            } else {
                DeckButtonKey(symbol: on ? "stop.circle.fill" : "record.circle",
                              title: on ? String(localized: "deck.recording") : String(localized: "deck.record"),
                              color: on ? deckRed : deckGrey, filled: on)
            }
        case .meeting(let m, let access):
            DeckMeetingKey(meeting: m, access: access)
        case .mic(let muted):
            DeckButtonKey(symbol: muted ? "mic.slash.fill" : "mic.fill",
                          title: muted ? String(localized: "deck.mic.off") : String(localized: "deck.mic.on"),
                          color: muted ? deckRed : deckGrey, filled: muted)
        case .output(let name):
            DeckButtonKey(symbol: outputSymbol(name), title: name, color: deckGrey, filled: false)
        case .focusPreset(let minutes, let isBreak, let active):
            DeckPresetKey(minutes: minutes, isBreak: isBreak, active: active)
        case .capture:
            DeckButtonKey(symbol: "camera.viewfinder", title: String(localized: "deck.capture"), color: deckGrey, filled: false)
        case .lock:
            DeckButtonKey(symbol: "lock.fill", title: String(localized: "deck.lock"), color: deckGrey, filled: false)
        case .vital(let kind, let value, let charging):
            DeckVitalPanel(kind: kind, value: value, charging: charging)
        case .usage(let week, let resets):
            DeckUsagePanel(week: week, resets: resets)
        case .focus(let s):
            DeckFocusPanel(session: s)
        case .music(let m):
            DeckMusicPanel(music: m, artwork: artwork)
        case .mochi(let state, let clock, let page, let pages):
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    MochiStill(state: botState(state), bodyHex: "#FFFFFF").frame(width: 72, height: 72)
                    Text(clock).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                // Which page the deck shows: swipe the strip for the others.
                HStack(spacing: 8) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Color.white : Color.white.opacity(0.3))
                            .frame(width: i == page ? 22 : 9, height: 9)
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 2)
        }
    }
}

private func outputSymbol(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("airpods max") { return "airpodsmax" }
    if n.contains("airpods pro") { return "airpodspro" }
    if n.contains("airpods") { return "airpods" }
    if n.contains("headphone") || n.contains("auricular") || n.contains("buds") || n.contains("headset") { return "headphones" }
    if n.contains("display") || n.contains("hdmi") || n.contains("monitor") { return "tv" }
    return "speaker.wave.2.fill"
}

/// The next meeting: how soon, and its name. Orange from 5 minutes before until it ends.
private struct DeckMeetingKey: View {
    let meeting: DeckSnapshot.Meeting?
    let access: DeckSnapshot.CalendarAccess

    var body: some View {
        if access != .granted {
            DeckButtonKey(symbol: "calendar", title: String(localized: "deck.meeting.calendar"), color: deckGrey, filled: false)
        } else if let m = meeting {
            let soon = m.minutes <= 5
            VStack(spacing: 2) {
                Text(when(m)).font(.system(size: 24, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(m.title).font(.system(size: 15, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                if m.hasLink {
                    Image(systemName: "video.fill").font(.system(size: 16, weight: .bold))
                }
            }
            .foregroundStyle(soon ? .white : deckOrange)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(soon ? deckOrange : Color.white.opacity(0.06)))
            .padding(3)
        } else {
            DeckButtonKey(symbol: "calendar", title: String(localized: "deck.meeting.none"), color: deckGrey, filled: false)
        }
    }

    private func when(_ m: DeckSnapshot.Meeting) -> String {
        if m.minutes <= 0 { return String(localized: "deck.meeting.now") }
        if m.minutes <= 60 { return String(format: String(localized: "deck.minutes %lld"), Int64(m.minutes)) }
        return m.start
    }
}

/// A focus or break length; filled while that timer runs.
private struct DeckPresetKey: View {
    let minutes: Int
    let isBreak: Bool
    let active: Bool

    var body: some View {
        let color = isBreak ? deckGreen : deckOrange
        VStack(spacing: 0) {
            Text(verbatim: "\(minutes)").font(.system(size: 46, weight: .heavy, design: .rounded))
            Text(isBreak ? String(localized: "deck.break") : String(localized: "deck.focus"))
                .font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(active ? .white : color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(active ? color : Color.white.opacity(0.06)))
        .padding(3)
    }
}

/// The focus timer across panels 1-3: the time left, and the strip as its progress bar.
private struct DeckTimerPanel: View {
    let timer: DeckSnapshot.FocusTimer

    var body: some View {
        let color = timer.isBreak ? deckGreen : deckOrange
        let done = timer.total > 0 ? 1 - Double(timer.remaining) / Double(timer.total) : 1
        VStack(alignment: .leading, spacing: 8) {
            // The time fills panel 1, the label starts on panel 2: no letter falls in a gap.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: String(format: "%d:%02d", timer.remaining / 60, timer.remaining % 60))
                    .font(.system(size: 50, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: CGFloat(DeckProtocol.stripSize.width) - 14, alignment: .leading)
                Spacer().frame(width: CGFloat(DeckProtocol.stripGap) + 10)
                Text(timer.isBreak ? String(localized: "deck.break") : String(localized: "deck.focus"))
                    .font(.system(size: 28, weight: .heavy)).foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: CGFloat(DeckProtocol.stripSize.width) - 20, alignment: .leading)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, done)))
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

/// CPU, memory or battery: a big number and a bar, red when it needs a look.
private struct DeckVitalPanel: View {
    let kind: DeckVital
    let value: Int?
    let charging: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                if charging { Image(systemName: "bolt.fill").font(.system(size: 15)).foregroundStyle(deckGreen) }
                Spacer()
                Text(verbatim: value.map { "\($0)%" } ?? "–").font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, Double(value ?? 0) / 100)))
                }
            }
            .frame(height: 14)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var label: String {
        switch kind {
        case .cpu: "CPU"
        case .memory: String(localized: "deck.vitals.memory")
        case .battery: String(localized: "deck.vitals.battery")
        }
    }

    private var color: Color {
        guard let v = value else { return deckGrey }
        if kind == .battery { return v <= 15 ? deckRed : v <= 30 ? deckOrange : deckGreen }
        return v >= 85 ? deckRed : v >= 60 ? deckOrange : deckGreen
    }
}

private struct DeckButtonKey: View {
    let symbol: String
    let title: String
    let color: Color
    var filled = true

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 46, weight: .bold))
            Text(title).font(.system(size: 18, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(filled ? .white : color)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(filled ? color : Color.white.opacity(0.06)))
        .padding(3)
    }
}

/// An agent session: Mochi in the agent's color, the project, and what it is doing.
private struct DeckSessionKey: View {
    let session: DeckSnapshot.Session
    let selected: Bool

    private var needsYou: Bool { session.state == "approval" || session.state == "question" }

    var body: some View {
        VStack(spacing: 0) {
            MochiStill(state: botState(session.state), bodyHex: "#FFFFFF",
                       pose: .idle(id: session.id, tick: 0))
                .frame(width: 68, height: 68)
                .background(Circle().fill(Color.mochiTile(hex: session.color)).frame(width: 62, height: 62))
                .padding(.top, 2)
            Text(session.project ?? session.agent)
                .font(.system(size: 19, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.55)
                .foregroundStyle(.white)
            Text(deckStateLabel(session.state))
                .font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(Color(hex: deckStateColor(session.state)))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(needsYou ? deckOrange : (selected ? .white : .clear), lineWidth: needsYou ? 5 : 3)
        )
        .padding(2)
    }
}

/// The weekly limit, big: the Max plan has no limit per session.
private struct DeckUsagePanel: View {
    let week: Double?
    let resets: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "deck.usage.week")).font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                Spacer()
                if let week {
                    Text(verbatim: "\(Int(week.rounded()))%").font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            if let week {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color(hex: ClaudePlanGauge.color(for: week)))
                            .frame(width: geo.size.width * min(1, max(0, week / 100)))
                    }
                }
                .frame(height: 14)
                if let resets {
                    Text(String(localized: "deck.usage.resets \(Self.day.string(from: resets))"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                Text(String(localized: "deck.usage.none")).font(.system(size: 17, weight: .semibold)).foregroundStyle(deckGrey)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return f
    }()
}

/// The session picked with knob 2 (white border on its key): what it is doing, in full.
private struct DeckFocusPanel: View {
    let session: DeckSnapshot.Session?

    var body: some View {
        if let s = session {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.project ?? s.agent).font(.system(size: 20, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(Color(hex: deckStateColor(s.state)))
                Text(s.step.isEmpty ? deckStateLabel(s.state) : s.step)
                    .font(.system(size: 17, weight: .semibold)).lineLimit(3).minimumScaleFactor(0.75)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(String(localized: "deck.sessions.none")).font(.system(size: 18, weight: .semibold)).foregroundStyle(deckGrey)
        }
    }
}

private struct DeckMusicPanel: View {
    let music: DeckSnapshot.Music?
    let artwork: NSImage?

    var body: some View {
        if let m = music {
            HStack(spacing: 8) {
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: m.playing ? "play.fill" : "pause.fill").font(.system(size: 16))
                        .foregroundStyle(m.playing ? deckGreen : deckGrey)
                    Text(m.title).font(.system(size: 18, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    Text(m.artist).font(.system(size: 14, weight: .semibold)).lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 36, weight: .semibold))
                Text(String(localized: "deck.music.none")).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(deckGrey)
        }
    }
}

/// One panel of a permission request or a question. The text is a grid of monospaced characters,
/// `DeckLayout.panelColumns` per panel, so the four panels read as one text and nothing falls in a gap.
private struct DeckRequestPanel: View {
    /// Panel 0 only.
    let title: String?
    /// nil: the request is answered on the Mac (a plan).
    let lines: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title ?? " ").font(.system(size: 15, weight: .heavy)).foregroundStyle(deckOrange)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 19, alignment: .leading)
            if let lines {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1).fixedSize()
                        .frame(height: 20, alignment: .leading)
                }
            } else if title != nil {
                Text(String(localized: "deck.plan.onMac"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(3).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

#endif

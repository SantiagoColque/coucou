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

        if case .request(let title, let body, let part) = tile {
            guard let image = requestImage(title: title, body: body),
                  let quarter = image.cropping(to: CGRect(x: part * size.width, y: 0, width: size.width, height: size.height))
            else { return nil }
            return encode(quarter)
        }
        let view = DeckTileView(tile: tile, artwork: artwork)
        guard let image = render(view, size: CGSize(width: size.width, height: size.height)) else { return nil }
        return encode(image)
    }

    /// The last request drawn: its four quarters come from one render.
    private static var lastRequest: (title: String, body: String?, image: CGImage)?

    private static func requestImage(title: String, body: String?) -> CGImage? {
        if let last = lastRequest, last.title == title, last.body == body { return last.image }
        let size = CGSize(width: DeckProtocol.stripSize.width * DeckProtocol.stripCount, height: DeckProtocol.stripSize.height)
        guard let image = render(DeckRequestPanel(title: title, text: body), size: size) else { return nil }
        lastRequest = (title, body, image)
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
        case .blank, .request:
            EmptyView()
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
                .font(.system(size: 17, weight: .bold))
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
            case .idle: DeckButtonKey(symbol: "mic", title: String(localized: "deck.dictation.hold"), color: deckGrey, filled: false)
            case .listening: DeckButtonKey(symbol: "mic.fill", title: String(localized: "deck.dictation.listening"), color: deckRed)
            case .thinking: DeckButtonKey(symbol: "ellipsis", title: "…", color: deckOrange)
            }
        case .record(let on):
            DeckButtonKey(symbol: on ? "stop.circle.fill" : "record.circle",
                          title: on ? String(localized: "deck.recording") : String(localized: "deck.record"),
                          color: on ? deckRed : deckGrey, filled: on)
        case .usage(let five, let week):
            DeckUsagePanel(fiveHour: five, week: week)
        case .focus(let s):
            DeckFocusPanel(session: s)
        case .music(let m):
            DeckMusicPanel(music: m, artwork: artwork)
        case .mochi(let state, let clock):
            HStack(spacing: 6) {
                MochiStill(state: botState(state), bodyHex: "#FFFFFF").frame(width: 84, height: 84)
                Text(clock).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
    }
}

private struct DeckButtonKey: View {
    let symbol: String
    let title: String
    let color: Color
    var filled = true

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 38, weight: .bold))
            Text(title).font(.system(size: 15, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(filled ? .white : color)
        .padding(6)
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
        VStack(spacing: 2) {
            MochiStill(state: botState(session.state), bodyHex: "#FFFFFF",
                       pose: .idle(id: session.id, tick: 0))
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.mochiTile(hex: session.color)).frame(width: 64, height: 64))
                .padding(.top, 6)
            Text(session.project ?? session.agent)
                .font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(.white)
            Text(session.step.isEmpty ? session.agent : session.step)
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(needsYou ? deckOrange : (selected ? .white : .clear), lineWidth: needsYou ? 5 : 3)
        )
        .padding(2)
    }
}

private struct DeckUsagePanel: View {
    let fiveHour: Double?
    let week: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            if fiveHour == nil && week == nil {
                Text(String(localized: "deck.usage.none")).font(.system(size: 13)).foregroundStyle(deckGrey)
            } else {
                bar("5 h", fiveHour)
                bar(String(localized: "deck.usage.week"), week)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bar(_ label: String, _ pct: Double?) -> some View {
        let p = pct ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Color(hex: ClaudePlanGauge.color(for: pct)))
                        .frame(width: geo.size.width * min(1, max(0, p / 100)))
                }
            }
            .frame(height: 8)
        }
    }
}

private struct DeckFocusPanel: View {
    let session: DeckSnapshot.Session?

    var body: some View {
        if let s = session {
            HStack(spacing: 8) {
                MochiStill(state: botState(s.state), bodyHex: "#FFFFFF", pose: .idle(id: s.id, tick: 1))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.mochiTile(hex: s.color)).frame(width: 54, height: 54))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.project ?? s.agent).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(s.agent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(s.step).font(.system(size: 12)).lineLimit(3).foregroundStyle(.white.opacity(0.85))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text(String(localized: "deck.sessions.none")).font(.system(size: 14)).foregroundStyle(deckGrey)
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
                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: m.playing ? "play.fill" : "pause.fill").font(.system(size: 12))
                        .foregroundStyle(m.playing ? deckGreen : deckGrey)
                    Text(m.title).font(.system(size: 14, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                    Text(m.artist).font(.system(size: 12)).lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 26))
                Text(String(localized: "deck.music.none")).font(.system(size: 13))
            }
            .foregroundStyle(deckGrey)
        }
    }
}

/// A permission request or a question, across the whole strip.
private struct DeckRequestPanel: View {
    let title: String
    /// nil: the request is answered on the Mac (a plan).
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(deckOrange).lineLimit(1)
            Text(text ?? String(localized: "deck.plan.onMac"))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(DeckLayout.maxCommandLines)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

#endif

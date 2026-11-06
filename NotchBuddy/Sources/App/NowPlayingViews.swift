#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Now playing pieces (Spotify and Apple Music cards, GitHub build only)

struct NowPlayingArtwork: View {
    let image: NSImage?
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(accent.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.25), value: image)
        .contentShape(Rectangle())
    }
}

/// Thin bar with elapsed / remaining time; drag or click anywhere on it to seek.
struct NowPlayingProgress: View {
    let position: Double
    let duration: Double
    let accent: Color
    let canSeek: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.format(fraction * duration))
                .frame(minWidth: 26, alignment: .trailing)
            NowPlayingBar(fraction: fraction, accent: accent, enabled: canSeek,
                       onChange: { dragFraction = $0 },
                       onCommit: { f in
                           onSeek(f * duration)
                           dragFraction = nil
                       })
                .frame(height: 10)
            Text(duration > 0 ? "-" + Self.format(max(0, duration - fraction * duration)) : "")
                .frame(minWidth: 28, alignment: .leading)
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundColor(Color(hex: "#6B7079"))
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NowPlayingVolume: View {
    let volume: Int
    let accent: Color
    let onChange: (Int) -> Void

    private var icon: String {
        switch volume {
        case 0:       return "speaker.slash.fill"
        case 1..<34:  return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default:      return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 13, alignment: .trailing)
            NowPlayingBar(fraction: Double(volume) / 100, accent: accent, enabled: true,
                       onChange: { onChange(Int(($0 * 100).rounded())) },
                       onCommit: { onChange(Int(($0 * 100).rounded())) })
                .frame(width: 44, height: 10)
        }
        .help(String(localized: "Volume \(volume)%"))
    }
}

/// Player slider: grey track, filled part turns green and grows a knob on hover.
struct NowPlayingBar: View {
    let fraction: Double
    let accent: Color
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let f = min(1, max(0, fraction))
            let active = enabled && (hovering || dragging)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: active ? 4 : 3)
                Capsule()
                    .fill(active ? accent : Color(hex: "#C5C8CD"))
                    .frame(width: w * f, height: active ? 4 : 3)
                if active {
                    Circle()
                        .fill(Color(hex: "#F5F6F8"))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: min(w - 9, max(0, w * f - 4.5)))
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        onChange(min(1, max(0, g.location.x / w)))
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        dragging = false
                        onCommit(min(1, max(0, g.location.x / w)))
                    }
            )
        }
    }
}

struct NowPlayingIconButton: View {
    let icon: String
    let size: CGFloat
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(hovered ? tint.opacity(1).lighter(by: 0.2) : tint)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .help(help)
    }
}

struct NowPlayingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - The song that just started, under the compact island

/// Same capsule as the vitals line (VitalsHoverLine), which keeps its place while the pointer is on Mochi.
struct NowPlayingToast: View {
    let islandW: CGFloat
    let islandH: CGFloat
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var vitals = MachineVitals.shared

    var body: some View {
        let track = state.mode == .compact && !vitals.hovered ? spotify.announced : nil
        ZStack {
            if let track {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: SpotifyController.green))
                        .frame(width: 6, height: 6)
                    Text(verbatim: track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 280)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .id(track.id)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: track?.id)
        .position(x: islandW / 2, y: islandH + 18)
        .allowsHitTesting(false)
    }
}
#endif

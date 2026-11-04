import SwiftUI

// Settings → General → Stream deck (GitHub build).

#if !APPSTORE

struct DeckSettingsBox: View {
    @ObservedObject private var deck = DeckService.shared
    @AppStorage(DeckService.enabledKey) private var enabled = false

    var body: some View {
        GroupBox(String(localized: "deck.title")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(String(localized: "deck.toggle"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in deck.setEnabled(on) }
                Text(String(localized: "deck.description"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled {
                    Label(deck.connected ? String(localized: "deck.status.connected") : String(localized: "deck.status.searching"),
                          systemImage: deck.connected ? "checkmark.circle.fill" : "cable.connector")
                        .font(.caption)
                        .foregroundColor(deck.connected ? .green : .secondary)
                }
            }
            .padding(6)
        }
    }
}

#endif

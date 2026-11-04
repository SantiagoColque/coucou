import SwiftUI

// MARK: - Which agent alerts open the island, and for how long
//
// Per kind of alert (a permission, a question, a finished task, an error): open the island always,
// only while no stream deck is connected, or never. An alert that does not open the island still
// shows on Mochi's pill (state, badge, sound) and on the stream deck. A finished task or an error
// that does open it folds again after its own delay; a permission or a question stays until answered.

enum NotchAlertKind: String, CaseIterable, Identifiable {
    case approval, question, finished, error
    var id: String { rawValue }

    init?(view: IslandView) {
        switch view {
        case .approval: self = .approval
        case .question: self = .question
        case .finished: self = .finished
        case .error: self = .error
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .approval: String(localized: "notch-alerts.approval")
        case .question: String(localized: "notch-alerts.question")
        case .finished: String(localized: "notch-alerts.finished")
        case .error: String(localized: "notch-alerts.error")
        }
    }

    /// Stays open until answered: no delay of its own.
    var waitsForAnswer: Bool { self == .approval || self == .question }

    var modeKey: String { "notchAlert.\(rawValue).mode" }
    var secondsKey: String { "notchAlert.\(rawValue).seconds" }
}

enum NotchAlertMode: String, CaseIterable, Identifiable {
    case always, withoutDeck, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: String(localized: "notch-alerts.always")
        case .withoutDeck: String(localized: "notch-alerts.without-deck")
        case .never: String(localized: "notch-alerts.never")
        }
    }

    /// The choices this build offers: the App Store build has no stream deck.
    static var offered: [NotchAlertMode] {
        #if APPSTORE
        [.always, .never]
        #else
        allCases
        #endif
    }
}

@MainActor
enum NotchAlerts {
    static let defaultSeconds: Double = 8
    static let minSeconds: Double = 2

    static func mode(_ kind: NotchAlertKind) -> NotchAlertMode {
        UserDefaults.standard.string(forKey: kind.modeKey).flatMap(NotchAlertMode.init(rawValue:)) ?? .always
    }

    /// Whether an alert shown as `view` may open (or take over) the island.
    static func opens(_ view: IslandView) -> Bool {
        guard let kind = NotchAlertKind(view: view) else { return true }
        switch mode(kind) {
        case .always: return true
        case .never: return false
        case .withoutDeck: return !deckConnected
        }
    }

    /// How long a finished task or an error keeps the island open; nil for the alerts that wait for an answer.
    static func seconds(for view: IslandView) -> Double? {
        guard let kind = NotchAlertKind(view: view), !kind.waitsForAnswer else { return nil }
        let value = UserDefaults.standard.object(forKey: kind.secondsKey) as? Double ?? defaultSeconds
        return max(minSeconds, value)
    }

    private static var deckConnected: Bool {
        #if APPSTORE
        false
        #else
        DeckService.shared.connected
        #endif
    }
}

// MARK: - Settings

/// Settings → General: one row per kind of alert.
struct NotchAlertsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "notch-alerts.help"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(NotchAlertKind.allCases) { kind in
                NotchAlertRow(kind: kind)
            }
        }
        .padding(6)
    }
}

private struct NotchAlertRow: View {
    let kind: NotchAlertKind
    @AppStorage private var mode: String
    @AppStorage private var seconds: Double

    init(kind: NotchAlertKind) {
        self.kind = kind
        _mode = AppStorage(wrappedValue: NotchAlertMode.always.rawValue, kind.modeKey)
        _seconds = AppStorage(wrappedValue: NotchAlerts.defaultSeconds, kind.secondsKey)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.title)
                .frame(width: 120, alignment: .leading)
            Picker("", selection: $mode) {
                ForEach(NotchAlertMode.offered) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 170)
            if mode != NotchAlertMode.never.rawValue {
                if kind.waitsForAnswer {
                    Text(String(localized: "notch-alerts.until-answered"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text(String(localized: "notch-alerts.close-after"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("8", value: Binding(
                        get: { seconds },
                        set: { seconds = max(NotchAlerts.minSeconds, $0) }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                    Text(verbatim: "s")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

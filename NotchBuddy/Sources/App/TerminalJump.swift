import AppKit
import ApplicationServices

// MARK: - Jumping to a session's terminal
//
// Shared by the stream deck's session keys and the island's "Open terminal": brings the terminal
// app forward, then the session's own window, native tab or split pane.

#if !APPSTORE

@MainActor
enum TerminalJump {
    /// Brings `task`'s terminal forward, then the window, tab or pane whose title is one of `names`
    /// (the conversation's title first, then the project). `found` is told where it sits on screen,
    /// nil when no title matched.
    static func jump(to task: AgentTask, names: [String], found: (@MainActor (CGPoint?) -> Void)? = nil) {
        if !(task.pill == "integration_claude" && ClaudeHost.activate(task.hostApp)),
           !TerminalTarget.activate(sessionBundleId: task.sessionBundleId) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            return
        }
        let apps = NSWorkspace.shared.runningApplications
        guard let terminal = [task.hostApp, task.sessionBundleId].compactMap({ $0 }).lazy
            .compactMap({ id in apps.first { $0.bundleIdentifier == id } }).first else { return }
        WindowFocus.front(pid: terminal.processIdentifier)
        // Once the terminal is in front (activating it brings its own front window): raised
        // before, the session's window would be covered again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                var spot: CGPoint?
                for name in names where spot == nil {
                    spot = WindowFocus.focus(pid: terminal.processIdentifier, names: [name])
                }
                WindowFocus.front(pid: terminal.processIdentifier)
                appendAppLog("nb.log", "[Jump] \(terminal.bundleIdentifier ?? "?"): \(spot == nil ? "no window matched" : "window found")")
                found?(spot)
            }
        }
    }
}

#endif

#if !APPSTORE

// MARK: - The session's own window, tab or pane

/// Brings forward the terminal window, or native tab, whose title names the session: Claude Code
/// titles its tab with the conversation, so two sessions in one terminal app are told apart.
/// Needs the Accessibility permission (Coucou asks for it for dictation); without it, or with no
/// title matching, it does nothing and the app alone is brought forward.
@MainActor
enum WindowFocus {
    /// Brings an app to the front. Since macOS 14 a background app's activate() request is ignored
    /// unless it is the active app itself; through Accessibility it still works.
    static func front(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Returns where the session's window, tab or pane sits on screen; nil when none matched.
    @discardableResult
    static func focus(pid: pid_t, names: [String]) -> CGPoint? {
        let wanted = names.map(normalize).filter { $0.count >= 3 }
        guard AXIsProcessTrusted(), !wanted.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        for window in elements(app, kAXWindowsAttribute) {
            if matches(string(window, kAXTitleAttribute), wanted) {
                // A window split in panes: its title is the focused pane's, which sits where that pane is.
                let panes = textAreas(in: window)
                let focusedPane = panes.count > 1 ? panes.first { bool($0, kAXFocusedAttribute) } : nil
                raise(window)
                return position(focusedPane ?? window)
            }
            // Native tabs: only the selected tab is a window; the others are buttons of its tab bar.
            for tab in tabs(in: window) where matches(string(tab, kAXTitleAttribute), wanted) {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                raise(window)
                return position(tab)
            }
        }
        // Split panes have no title of their own: the window takes the focused pane's. Each pane is
        // focused in turn until the window's title names the session; failing that, focus goes back.
        for window in elements(app, kAXWindowsAttribute) {
            let panes = textAreas(in: window)
            guard panes.count > 1 else { continue }
            let before = panes.first { bool($0, kAXFocusedAttribute) }
            for pane in panes {
                AXUIElementSetAttributeValue(pane, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if waitForTitle(of: window, wanted) {
                    raise(window)
                    return position(pane)
                }
            }
            if let before { AXUIElementSetAttributeValue(before, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        }
        return nil
    }

    private static func position(_ e: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    /// The terminal sets its title a moment after the focus moves: looked at for up to 150 ms.
    private static func waitForTitle(of window: AXUIElement, _ wanted: [String]) -> Bool {
        for _ in 0..<6 {
            if matches(string(window, kAXTitleAttribute), wanted) { return true }
            usleep(25_000)
        }
        return false
    }

    /// The panes of a split: one text area each.
    private static func textAreas(in e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        var found: [AXUIElement] = []
        for child in elements(e, kAXChildrenAttribute) {
            if string(child, kAXRoleAttribute) == (kAXTextAreaRole as String) { found.append(child) }
            else { found += textAreas(in: child, depth: depth + 1) }
        }
        return found
    }

    private static func bool(_ e: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func matches(_ title: String?, _ wanted: [String]) -> Bool {
        guard let title else { return false }
        let t = normalize(title)
        guard !t.isEmpty else { return false }
        return wanted.contains { t.contains($0) || $0.contains(t) }
    }

    /// Lowercased, without the spinner or status signs Claude Code puts before the title.
    private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .drop { !CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func tabs(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 4 else { return }
            for child in elements(e, kAXChildrenAttribute) {
                if string(child, kAXRoleAttribute) == (kAXTabGroupRole as String) {
                    found += elements(child, kAXTabsAttribute).isEmpty ? elements(child, kAXChildrenAttribute) : elements(child, kAXTabsAttribute)
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(window, depth: 0)
        return found
    }

    private static func elements(_ e: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

#endif

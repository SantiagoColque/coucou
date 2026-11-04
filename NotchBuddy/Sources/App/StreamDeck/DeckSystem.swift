import AppKit
import CoreAudio
import Darwin
import EventKit
import IOKit.ps

// MARK: - What the deck reads from the Mac and changes on it
//
// The next meeting (the Mac's Calendar, read on the Mac only), the microphone and the audio output
// (CoreAudio), CPU, memory and battery, and locking the screen. Everything is read when the deck
// draws, never in the background: with the deck off, nothing here runs.

#if !APPSTORE

// MARK: Calendar

@MainActor
enum DeckCalendar {
    private static let store = EKEventStore()

    static var access: DeckSnapshot.CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Asks once; after a refusal, opens the Calendars privacy pane where it can be turned on.
    static func ask(then done: @escaping @MainActor () -> Void) {
        guard access == .notAsked else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task { @MainActor in
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            DeckDevice.log("calendar access \(ok ? "granted" : "refused")")
            done()
        }
    }

    /// The meeting on now or the next one today (all-day events and declined ones left out).
    static func next(now: Date = Date()) -> EKEvent? {
        guard access == .granted else { return nil }
        guard let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: endOfDay, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && !declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    static func snapshot(_ event: EKEvent?, now: Date = Date()) -> DeckSnapshot.Meeting? {
        guard let event else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up))
        return .init(title: event.title ?? "", minutes: minutes, start: f.string(from: event.startDate),
                     hasLink: link(event) != nil)
    }

    /// The video call link: Meet, Zoom, Teams, Webex, or the event's own URL.
    static func link(_ event: EKEvent) -> URL? {
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co"]
        for text in [event.url?.absoluteString, event.location, event.notes].compactMap({ $0 }) {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { break }
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let host = url.host?.lowercased(),
                   url.scheme == "https", hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        if let url = event.url, url.scheme == "https" { return url }
        return nil
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}

// MARK: Audio

@MainActor
enum DeckAudio {
    private static let micVolumeKey = "streamDeckMicVolume"

    // Microphone

    /// nil: no microphone.
    static func micMuted() -> Bool? {
        guard let mic = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        if let mute = uint32(mic, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)), canMute(mic) {
            return mute != 0
        }
        guard let volume = inputVolume(mic) else { return nil }
        return volume < 0.01
    }

    /// Mutes or unmutes the default microphone, with its own mute or, without one, its volume.
    static func toggleMic() {
        guard let mic = defaultDevice(kAudioHardwarePropertyDefaultInputDevice), let muted = micMuted() else { return }
        if canMute(mic) {
            var where_ = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
            var value: UInt32 = muted ? 0 : 1
            AudioObjectSetPropertyData(mic, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            return
        }
        if muted {
            let saved = UserDefaults.standard.object(forKey: micVolumeKey) as? Float ?? 0.75
            setInputVolume(mic, max(saved, 0.1))
        } else {
            if let v = inputVolume(mic) { UserDefaults.standard.set(v, forKey: micVolumeKey) }
            setInputVolume(mic, 0)
        }
    }

    // Output

    static func outputName() -> String? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap(name)
    }

    /// The next output device, in the system's order (aggregate and hidden ones left out).
    static func nextOutput() {
        let outputs = allDevices().filter { hasStreams($0, kAudioObjectPropertyScopeOutput) && !isAggregate($0) }
        guard outputs.count > 1, let current = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return }
        let i = outputs.firstIndex(of: current) ?? -1
        var next = outputs[(i + 1) % outputs.count]
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &next)
        // System sounds follow the output.
        var system = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &system, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &next)
    }

    /// Calls `changed` when the default microphone or output changes.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> [AudioObjectPropertyAddress] {
        let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]
        var addresses: [AudioObjectPropertyAddress] = []
        for selector in selectors {
            var where_ = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &where_, DispatchQueue.main) { _, _ in
                MainActor.assumeIsolated { changed() }
            }
            addresses.append(where_)
        }
        return addresses
    }

    // CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var where_ = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    private static func allDevices() -> [AudioObjectID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var where_ = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr && size > 0
    }

    private static func isAggregate(_ device: AudioObjectID) -> Bool {
        uint32(device, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeAggregate
            || (uint32(device, address(kAudioDevicePropertyIsHidden)) ?? 0) != 0
    }

    private static func name(_ device: AudioObjectID) -> String? {
        var where_ = address(kAudioObjectPropertyName)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &where_, 0, nil, &size, $0) }
        return status == noErr ? value as String : nil
    }

    private static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var where_ = address
        guard AudioObjectHasProperty(object, &where_) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var where_ = address
        guard AudioObjectHasProperty(object, &where_) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &where_, &ok) == noErr && ok.boolValue
    }

    private static func canMute(_ mic: AudioObjectID) -> Bool {
        settable(mic, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput))
    }

    private static func inputVolume(_ mic: AudioObjectID) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var where_ = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            guard AudioObjectHasProperty(mic, &where_) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(mic, &where_, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    private static func setInputVolume(_ mic: AudioObjectID, _ value: Float32) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let where_ = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            guard settable(mic, where_) else { continue }
            var w = where_
            var v = value
            AudioObjectSetPropertyData(mic, &w, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }
}

// MARK: CPU, memory, battery

@MainActor
final class DeckVitals {
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func sample() -> DeckSnapshot.Vitals {
        var battery: Int?
        var charging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                battery = cur * 100 / max
                charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            }
        }
        return .init(cpu: cpu(), memory: memory(), battery: battery, charging: charging)
    }

    private func cpu() -> Int {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpus) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Int((Double(busy - last.busy) / Double(total - last.total) * 100).rounded())
    }

    private func memory() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        // What Activity Monitor calls "memory used": app memory, wired and compressed.
        let used = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return Int((Double(used) / Double(ProcessInfo.processInfo.physicalMemory) * 100).rounded())
    }
}

// MARK: Lock

enum DeckLock {
    /// Locks the screen at once, as Control-Command-Q does.
    static func now() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: Lock.self)()
            return
        }
        appendAppLog("StreamDeck.log", "could not lock the screen")
    }
}

#endif

#if !APPSTORE

// MARK: The session's own window or tab

/// Brings forward the terminal window, or native tab, whose title names the session: Claude Code
/// titles its tab with the conversation, so two sessions in one terminal app are told apart.
/// Needs the Accessibility permission (Coucou asks for it for dictation); without it, or with no
/// title matching, it does nothing and the app alone is brought forward.
@MainActor
enum DeckWindowFocus {
    /// Brings an app to the front. Since macOS 14 a background app's activate() request is ignored
    /// unless it is the active app itself; through Accessibility it still works.
    static func front(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    static func focus(pid: pid_t, names: [String]) -> Bool {
        let wanted = names.map(normalize).filter { $0.count >= 3 }
        guard AXIsProcessTrusted(), !wanted.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        for window in elements(app, kAXWindowsAttribute) {
            if matches(string(window, kAXTitleAttribute), wanted) {
                raise(window)
                return true
            }
            // Native tabs: only the selected tab is a window; the others are buttons of its tab bar.
            for tab in tabs(in: window) where matches(string(tab, kAXTitleAttribute), wanted) {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                raise(window)
                return true
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
                    return true
                }
            }
            if let before { AXUIElementSetAttributeValue(before, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        }
        return false
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

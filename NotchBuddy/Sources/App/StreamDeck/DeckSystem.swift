import AppKit
import CoreAudio
import Darwin
import IOKit.ps

// MARK: - What the deck reads from the Mac and changes on it
//
// The microphone and the audio output (CoreAudio), CPU, memory and battery, and locking the screen. Everything is read when the deck
// draws, never in the background: with the deck off, nothing here runs.

#if !APPSTORE

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

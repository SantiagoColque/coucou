import Foundation
import IOKit.hid

// MARK: - The stream deck over USB (IOHIDManager, no third-party code)
//
// Finds the deck's own HID interface (usage page 0xFFA0; the device also exposes a keyboard we
// never open), reads its input reports on the main run loop, and writes output reports on a serial
// background queue so a 14-screen upload never stalls the island.
//
// Only one app can drive the deck: another deck app (OpenDeck, StreamDock) running at the same time
// draws over Coucou and gets the same key presses.

#if !APPSTORE

@MainActor
final class DeckDevice {
    var onEvent: (@MainActor (DeckProtocol.Event) -> Void)?
    /// true once the deck is connected and initialized, false when it is unplugged.
    var onConnection: (@MainActor (Bool) -> Void)?
    /// A batch of reports could not be written: what the deck shows is unknown.
    var onWriteFailed: (@MainActor () -> Void)?
    private(set) var isConnected = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var keepAlive: Timer?
    private let writer = DispatchQueue(label: "fr.louisraille.NotchBuddy.deck-writer", qos: .userInitiated)

    /// IOHIDDevice is a CF object: handed to the main actor by the IOKit callbacks (which run on the
    /// main run loop anyway) and used for writes on the writer queue only.
    private struct DeviceRef: @unchecked Sendable { let device: IOHIDDevice }

    static func log(_ message: String) { appendAppLog("StreamDeck.log", message) }

    // MARK: Start and stop

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: DeckProtocol.vendorId,
            kIOHIDProductIDKey: DeckProtocol.productId,
            kIOHIDPrimaryUsagePageKey: DeckProtocol.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<DeckDevice>.fromOpaque(context).takeUnretainedValue()
            let ref = DeviceRef(device: device)
            MainActor.assumeIsolated { me.attach(ref.device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<DeckDevice>.fromOpaque(context).takeUnretainedValue()
            let ref = DeviceRef(device: device)
            MainActor.assumeIsolated { me.detach(ref.device) }
        }, context)
        // Common modes: the deck keeps working while a menu is open.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { Self.log("could not open the HID manager: \(result)") }
        self.manager = manager
        Self.log("watching for the deck")
    }

    func stop() {
        // Reports queued just before (clearing the screens) are written while the device is still open.
        writer.sync {}
        if let device { detach(device) }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        Self.log("stopped")
    }

    // MARK: Connection

    private func attach(_ newDevice: IOHIDDevice) {
        guard device == nil else { return } // one deck at a time
        device = newDevice
        let size = (IOHIDDeviceGetProperty(newDevice, kIOHIDMaxInputReportSizeKey as CFString) as? Int)
            ?? DeckProtocol.inputReportSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        inputBuffer = buffer
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(newDevice, buffer, size, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            let me = Unmanaged<DeckDevice>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.received(bytes) }
        }, context)

        send([DeckProtocol.initialize(), DeckProtocol.clearAll(), DeckProtocol.commit()])
        // The deck falls back to its own clock screen without a sign of life every few seconds.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send([DeckProtocol.keepAlive()]) }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
        isConnected = true
        Self.log("deck connected")
        onConnection?(true)
    }

    private func detach(_ gone: IOHIDDevice) {
        guard let device, CFEqual(device, gone) else { return }
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer!, 0, nil, nil)
        keepAlive?.invalidate()
        keepAlive = nil
        self.device = nil
        // Unregistered above, on the run loop that delivers input reports: nothing reads it any more.
        inputBuffer?.deallocate()
        inputBuffer = nil
        isConnected = false
        Self.log("deck disconnected")
        onConnection?(false)
    }

    // MARK: Reports

    private func received(_ report: [UInt8]) {
        if let event = DeckProtocol.parse(report) {
            onEvent?(event)
        } else if report.starts(with: Array("ACK".utf8)), report.count > 10 {
            // Unknown control: logged so a missing mapping can be added (tools/streamdeck/ss552_probe.py).
            Self.log(String(format: "unknown input 0x%02x state 0x%02x", report[9], report[10]))
        }
    }

    /// Queues output reports, in order. Dropped while no deck is connected.
    func send(_ reports: [[UInt8]]) {
        guard let device, !reports.isEmpty else { return }
        let ref = DeviceRef(device: device)
        writer.async {
            for report in reports {
                let result = report.withUnsafeBufferPointer { bytes in
                    IOHIDDeviceSetReport(ref.device, kIOHIDReportTypeOutput, 0, bytes.baseAddress!, bytes.count)
                }
                if result != kIOReturnSuccess {
                    appendAppLog("StreamDeck.log", "write failed: \(result)")
                    // The rest of this batch would land half drawn: everything is drawn again next time.
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onWriteFailed?() } }
                    return
                }
            }
        }
    }
}

#endif

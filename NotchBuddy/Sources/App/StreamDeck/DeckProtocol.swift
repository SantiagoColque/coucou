import Foundation

// MARK: - Stream deck wire protocol (Redragon SS552 / Mirabox N4 family)
//
// Mirabox never published it; this follows github.com/4ndv/mirajazz (protocol v3) and
// github.com/ambiso/opendeck-akp05, checked against a real SS552 (0200:3001) with
// tools/streamdeck/ss552_probe.py.
//
// Output reports are 1024 bytes, no report id. A command is "CRT\0\0" + an ASCII verb + arguments.
// Images are JPEG, rotated 180°, sent as a BAT header followed by the raw bytes in 1024-byte reports,
// and shown on STP. Input reports start with "ACK"; byte 9 is the control, byte 10 the key state.
//
// Pure Foundation: compiled by tests/DeckProtocolTests.swift on any platform.

#if !APPSTORE

enum DeckProtocol {
    static let vendorId = 0x0200
    static let productId = 0x3001
    /// The deck's own interface; the device also exposes a plain keyboard we leave alone.
    static let usagePage = 0xFFA0
    static let packetSize = 1024
    static let inputReportSize = 512

    static let keyCount = 10
    static let stripCount = 4
    static let keySize = (width: 112, height: 112)
    static let stripSize = (width: 176, height: 112)

    // MARK: Screens

    /// A screen: one of the 10 keys (0 = top left, row by row) or one of the 4 touch strip panels (0 = left).
    enum Screen: Hashable, Sendable {
        case key(Int)
        case strip(Int)

        /// The slot number the device uses for this screen (measured: top row 11-15, bottom row 6-10, strip 1-4).
        var wireSlot: UInt8 {
            switch self {
            case .key(let k): return UInt8(k < 5 ? 11 + k : 6 + (k - 5))
            case .strip(let s): return UInt8(1 + s)
            }
        }

        static let all: [Screen] = (0..<keyCount).map { .key($0) } + (0..<stripCount).map { .strip($0) }
    }

    // MARK: Commands

    static func command(_ verb: String, _ args: [UInt8] = []) -> [UInt8] {
        var report = Array("CRT".utf8) + [0, 0] + Array(verb.utf8) + args
        precondition(report.count <= packetSize)
        report += [UInt8](repeating: 0, count: packetSize - report.count)
        return report
    }

    static func initialize() -> [UInt8] { command("DIS") }
    static func brightness(_ percent: Int) -> [UInt8] { command("LIG", [0, 0, UInt8(max(0, min(100, percent)))]) }
    static func clearAll() -> [UInt8] { command("CLE", [0, 0, 0, 0xFF]) }
    static func commit() -> [UInt8] { command("STP") }
    static func keepAlive() -> [UInt8] { command("CONNECT") }
    /// Screens off until the next command; the device stays connected.
    static func sleep() -> [UInt8] { command("HAN") }

    /// The reports that put a JPEG on a screen. Nothing shows until `commit()`.
    /// Empty for a JPEG over 64 KB (the length field is two bytes; real tiles are 5-20 KB).
    static func image(_ jpeg: [UInt8], on screen: Screen) -> [[UInt8]] {
        guard jpeg.count <= 0xFFFF else { return [] }
        var reports = [command("BAT", [0, 0, UInt8(jpeg.count >> 8), UInt8(jpeg.count & 0xFF), screen.wireSlot])]
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + packetSize, jpeg.count)
            var chunk = Array(jpeg[offset..<end])
            chunk += [UInt8](repeating: 0, count: packetSize - chunk.count)
            reports.append(chunk)
            offset = end
        }
        return reports
    }

    // MARK: Input

    enum Event: Equatable, Sendable {
        case keyDown(Int)
        case keyUp(Int)
        /// steps: -1 counter-clockwise, +1 clockwise.
        case knobTurn(knob: Int, steps: Int)
        case knobPress(Int)
        case stripTap(Int)
        /// left: the finger moved right to left.
        case swipe(left: Bool)
    }

    /// nil for anything that is not a known control (keep-alive acks, unknown codes).
    static func parse(_ report: [UInt8]) -> Event? {
        guard report.count >= 11, report.starts(with: Array("ACK".utf8)) else { return nil }
        let code = report[9], state = report[10]
        switch code {
        case 1...10:
            let key = Int(code) - 1
            return state == 0 ? .keyUp(key) : .keyDown(key)
        case 0xA0: return .knobTurn(knob: 0, steps: -1)
        case 0xA1: return .knobTurn(knob: 0, steps: 1)
        case 0x50: return .knobTurn(knob: 1, steps: -1)
        case 0x51: return .knobTurn(knob: 1, steps: 1)
        case 0x90: return .knobTurn(knob: 2, steps: -1)
        case 0x91: return .knobTurn(knob: 2, steps: 1)
        case 0x70: return .knobTurn(knob: 3, steps: -1)
        case 0x71: return .knobTurn(knob: 3, steps: 1)
        // Measured on an SS552: knob 1 press = 0x37, strip panel 1 tap = 0x40. Presses and taps arrive once,
        // with no release (holding a knob sends nothing more), so neither supports long press.
        case 0x37: return .knobPress(0)
        case 0x35: return .knobPress(1)
        case 0x33: return .knobPress(2)
        case 0x36: return .knobPress(3)
        case 0x40...0x43: return .stripTap(Int(code - 0x40))
        case 0x38: return .swipe(left: false) // measured: finger moving left to right
        case 0x39: return .swipe(left: true)
        default: return nil
        }
    }
}

#endif

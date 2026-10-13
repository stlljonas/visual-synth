import CoreMIDI
import Foundation
import QuartzCore

/// Listens to every MIDI source (USB class-compliant devices like the KeyStep show up
/// on their own) and reconnects when devices are plugged in or out.
final class MIDIInput {
    private let engine: Engine
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    private enum Event {
        case noteOn(Int, Int), noteOff(Int), cc(Int, Int), clock(CFTimeInterval), start, other
    }

    init(engine: Engine) {
        self.engine = engine
        let status = MIDIClientCreateWithBlock("VisualSynth" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard status == noErr else {
            NSLog("MIDI client error \(status)")
            return
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        connectAll()
    }

    func connectAll() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected = []
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard MIDIPortConnectSource(port, src, nil) == noErr else { continue }
            connected.append(src)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name {
                names.append(n.takeRetainedValue() as String)
            }
        }
        engine.midiDevices = names
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        let now = CACurrentMediaTime()
        var events: [Event] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words = withUnsafeBytes(of: packet.pointee.words) { raw in
                (0..<min(count, 64)).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self) }
            }
            var i = 0
            while i < words.count {
                let w = words[i]
                let type = Int(w >> 28)
                events.append(Self.parse(w, type: type, at: now))
                i += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
            }
        }
        DispatchQueue.main.async { [engine] in
            for e in events {
                switch e {
                case let .noteOn(n, v): engine.noteOn(n, velocity: v)
                case let .noteOff(n): engine.noteOff(n)
                case let .cc(c, v): engine.controlChange(c, value: v)
                case let .clock(t): engine.clockTick(at: t)
                case .start: engine.clockStart()
                case .other: break
                }
            }
            if events.contains(where: { if case .clock = $0 { return false } else { return true } }) {
                engine.midiSeen()
            }
        }
    }

    private static func parse(_ w: UInt32, type: Int, at t: CFTimeInterval) -> Event {
        switch type {
        case 0x1: // system real-time
            switch (w >> 16) & 0xFF {
            case 0xF8: return .clock(t)
            case 0xFA: return .start
            default: return .other
            }
        case 0x2: // MIDI 1.0 channel voice
            let status = Int((w >> 16) & 0xF0)
            let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
            switch status {
            case 0x90: return d2 > 0 ? .noteOn(d1, d2) : .noteOff(d1)
            case 0x80: return .noteOff(d1)
            case 0xB0: return .cc(d1, d2)
            default: return .other
            }
        default:
            return .other
        }
    }
}

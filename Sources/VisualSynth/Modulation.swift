import Foundation
import QuartzCore

/// Modulators: LFOs, an envelope and a random source, plus fixed sources (audio, notes, mod wheel).
/// Any slider can be routed to one source (right-click → Modulate by…) with a depth.
enum Modulators {
    static let rates: [(String, Double)] = [
        ("1/16", 0.25), ("1/8", 0.5), ("1/4", 1), ("1/2", 2), ("1 bar", 4), ("2 bars", 8),
        ("4 bars", 16), ("8 bars", 32), ("16 bars", 64),
    ]

    static func lfo(_ n: Int, rate: Int, shape: Int = 0) -> ModuleSpec {
        ModuleSpec(id: "lfo\(n)", name: "LFO \(n)", kind: .modulator, function: "", params: [
            .choice("shape", "Shape", ["Sine", "Triangle", "Saw ↗", "Saw ↘", "Square", "S&H", "Smooth rnd"], shape),
            .choice("rate", "Cycle", rates.map(\.0), rate, help: "Length of one cycle, synced to the beat"),
            .range("phase", "Phase", 0, 1, 0),
            .range("free", "Free rate", 0, 4, 0, unit: " Hz", help: "Above 0: ignore the beat, run at this rate"),
        ], enabled: true, help: "Low-frequency oscillator, synced to the beat. Output −1…1")
    }

    static let all: [ModuleSpec] = [
        lfo(1, rate: 4), lfo(2, rate: 2, shape: 1), lfo(3, rate: 6, shape: 6), lfo(4, rate: 3, shape: 5),
        ModuleSpec(id: "env", name: "Envelope", kind: .modulator, function: "", params: [
            .range("attack", "Attack", 0.001, 2, 0.01, unit: " s"),
            .range("decay", "Decay", 0.01, 4, 0.3, unit: " s"),
            .range("sustain", "Sustain", 0, 1, 0.4),
            .range("release", "Release", 0.01, 6, 0.6, unit: " s"),
        ], enabled: true, help: "ADSR envelope played by MIDI notes (and keys A–K). Output 0…1"),
        ModuleSpec(id: "rand", name: "Note Random", kind: .modulator, function: "", params: [
            .range("glide", "Glide", 0, 2, 0.1, unit: " s"),
            .choice("trigger", "New value", ["Each note", "Each beat", "Each bar"]),
        ], enabled: true, help: "A new random value on each note (or beat / bar), gliding there. Output 0…1"),
    ]

    /// Every source a slider can follow: id, display name, bipolar (−1…1) or not (0…1).
    static let sources: [(id: String, name: String, bipolar: Bool)] = [
        ("lfo1", "LFO 1", true), ("lfo2", "LFO 2", true), ("lfo3", "LFO 3", true), ("lfo4", "LFO 4", true),
        ("env", "Envelope", false), ("rand", "Note Random", false), ("pulse", "Note pulse", false),
        ("bass", "Audio bass", false), ("mid", "Audio mid", false), ("high", "Audio high", false),
        ("level", "Audio loudness", false),
        ("pitch", "Note pitch", false), ("velocity", "Velocity", false), ("modwheel", "Mod wheel", false),
    ]

    static func index(of id: String) -> Int? { sources.firstIndex { $0.id == id } }
}

/// Per-frame state of the modulators (envelope stage, random targets…).
struct ModState {
    var env: Float = 0
    var envStage = 0          // 0 idle, 1 attack, 2 decay/sustain, 3 release
    var heldBefore = false
    var trigSeen: Float = 0
    var rand: Float = 0.5
    var randTarget: Float = 0.5
    var lastRandBeat = -1

    static func hash(_ x: Double) -> Float {
        Float((sin(x * 127.1 + 311.7) * 43758.5453).truncatingRemainder(dividingBy: 1)).magnitude
    }

    static func lfo(shape: Int, phase: Double) -> Float {
        let f = Float(phase - floor(phase))
        switch shape {
        case 0: return sin(f * 2 * .pi)
        case 1: return 1 - 4 * abs(f - 0.5)
        case 2: return f * 2 - 1
        case 3: return 1 - f * 2
        case 4: return f < 0.5 ? 1 : -1
        case 5: return hash(floor(phase)) * 2 - 1
        default:
            let a = hash(floor(phase)), b = hash(floor(phase) + 1)
            let t = f * f * (3 - 2 * f)
            return (a + (b - a) * t) * 2 - 1
        }
    }
}

// MARK: - Palette

enum Palettes {
    /// Five colour stops each (r, g, b in 0…1); layers in palette mode pick colours along this loop.
    static let presets: [(String, [SIMD3<Float>])] = [
        ("Neon", [[1, 0.1, 0.8], [0.1, 0.9, 1], [0.5, 0.2, 1], [0.6, 1, 0.2], [1, 0.3, 0.5]]),
        ("Sunset", [[1, 0.35, 0.2], [1, 0.62, 0.1], [0.95, 0.2, 0.45], [0.55, 0.15, 0.6], [1, 0.85, 0.4]]),
        ("Ocean", [[0, 0.3, 0.65], [0, 0.72, 0.8], [0.2, 0.9, 0.7], [0.1, 0.4, 0.95], [0.6, 0.95, 1]]),
        ("Fire", [[1, 0.12, 0], [1, 0.45, 0], [1, 0.8, 0.1], [0.75, 0.05, 0.05], [1, 0.95, 0.6]]),
        ("Ice", [[0.7, 0.9, 1], [0.3, 0.6, 1], [0.92, 0.96, 1], [0.4, 0.8, 0.95], [0.2, 0.35, 0.9]]),
        ("Acid", [[0.7, 1, 0], [1, 0, 0.6], [0, 1, 0.8], [1, 0.9, 0], [0.5, 0, 1]]),
        ("Pastel", [[1, 0.7, 0.8], [0.7, 0.85, 1], [0.75, 1, 0.8], [1, 0.95, 0.7], [0.85, 0.75, 1]]),
        ("Vapor", [[1, 0.45, 0.85], [0.45, 0.35, 1], [0.3, 0.95, 1], [1, 0.75, 0.55], [0.7, 0.4, 1]]),
        ("Mono", [[1, 1, 1], [0.55, 0.55, 0.55], [1, 1, 1], [0.8, 0.8, 0.8], [0.35, 0.35, 0.35]]),
    ]

    static let spec = ModuleSpec(id: "palette", name: "Colour Palette", kind: .palette, function: "", params: [
        .choice("preset", "Palette", presets.map(\.0) + ["Custom"], 0),
        .range("shift", "Shift", 0, 1, 0, help: "Rotate all layers along the palette (try drift or an LFO)"),
        .range("spread", "Spread", 0, 2, 1, help: "How far apart the layers' colours sit on the palette"),
    ], enabled: false, help: "When on, layers take their colours from this palette; their Hue picks the spot on it")
}

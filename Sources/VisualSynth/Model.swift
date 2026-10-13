import AppKit
import Foundation
import Observation

// MARK: - Specs (static descriptions, see Generators.swift / Effects.swift)

enum ModuleKind: String, Codable {
    case generator, effect, master, modulator, palette
}

/// One slider (or option picker) of a module. Its value lands in the module's
/// `p[i]` float array in the shader, in declaration order (max 16).
struct ParamSpec {
    let key: String
    let name: String
    let min: Float
    let max: Float
    let def: Float
    var integer = false
    var options: [String]? = nil
    var unit = ""
    var help: String? = nil

    /// A continuous slider.
    static func range(_ key: String, _ name: String, _ min: Float, _ max: Float, _ def: Float,
                      unit: String = "", help: String? = nil) -> ParamSpec {
        ParamSpec(key: key, name: name, min: min, max: max, def: def, unit: unit, help: help)
    }

    /// A whole-number slider (value arrives in the shader as a whole float).
    static func int(_ key: String, _ name: String, _ min: Int, _ max: Int, _ def: Int,
                    unit: String = "", help: String? = nil) -> ParamSpec {
        ParamSpec(key: key, name: name, min: Float(min), max: Float(max), def: Float(def),
                  integer: true, unit: unit, help: help)
    }

    /// A choice between named options (value = index 0, 1, 2 … in the shader).
    static func choice(_ key: String, _ name: String, _ options: [String], _ def: Int = 0,
                       help: String? = nil) -> ParamSpec {
        ParamSpec(key: key, name: name, min: 0, max: Float(options.count - 1), def: Float(def),
                  integer: true, options: options, help: help)
    }
}

struct ModuleSpec {
    /// Stable id, used for presets. Never rename once shipped.
    let id: String
    let name: String
    let kind: ModuleKind
    /// Name of the Metal fragment function.
    let function: String
    let params: [ParamSpec]
    var enabled = false
    /// Default hue of a generator's colour (0…1).
    var hue: Float = 0.6
    var help = ""
    /// Effect samples `src` at coarser mip levels (wide blurs): the renderer builds mipmaps first.
    var mips = false
}

// MARK: - Live state

@Observable
final class Param: Identifiable {
    let spec: ParamSpec
    var value: Float
    /// MIDI CC number mapped to this parameter (MIDI learn).
    var cc: Int?
    /// Smooth random walk: the value drifts on its own (speed: Master › Drift speed).
    var walk = false
    @ObservationIgnored private var walkVel: Float = 0
    /// Modulation route: source id (see Modulators.sources) and its depth (−1…1 of the range).
    var modSource: String?
    var modDepth: Param?
    @ObservationIgnored private var modIndex: Int?

    var id: String { spec.key }

    init(_ spec: ParamSpec) {
        self.spec = spec
        self.value = spec.def
    }

    var range: Float { spec.max - spec.min }

    var normalized: Float {
        get { range == 0 ? 0 : (value - spec.min) / range }
        set { value = spec.min + Swift.min(Swift.max(newValue, 0), 1) * range }
    }

    /// The value the shader sees.
    var packed: Float { spec.integer ? value.rounded() : value }

    var display: String { format(value) }

    func format(_ v: Float) -> String {
        if let options = spec.options {
            return options[Swift.min(Swift.max(Int(v.rounded()), 0), options.count - 1)]
        }
        if spec.integer { return "\(Int(v.rounded()))\(spec.unit)" }
        let digits = range >= 100 ? 0 : (range >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f", v) + spec.unit
    }

    func reset() { value = spec.def }

    func route(to source: String?, depth: Float = 0.5) {
        modSource = source
        modIndex = source.flatMap(Modulators.index(of:))
        if source == nil {
            modDepth = nil
        } else if modDepth == nil {
            let d = Param(.range("\(spec.key)~depth", "Depth", -1, 1, depth, help: "How far the modulator moves this slider"))
            d.value = depth
            modDepth = d
        }
    }

    /// The value after modulation (what the shader sees, before rounding).
    func effective(_ mods: [Float]) -> Float {
        guard let i = modIndex, i < mods.count, let d = modDepth else { return value }
        return clamp(value + d.value * range * mods[i])
    }

    func packed(_ mods: [Float]) -> Float {
        let v = effective(mods)
        return spec.integer ? v.rounded() : v
    }

    func randomize() {
        if spec.options != nil || spec.integer {
            value = Float(Int.random(in: Int(spec.min)...Int(spec.max)))
        } else {
            value = Float.random(in: spec.min...spec.max)
        }
    }

    /// Scroll wheel / trackpad adjustment. Up (or right) increases.
    func nudge(with event: NSEvent) {
        var d = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? Float(event.scrollingDeltaY) : -Float(event.scrollingDeltaX)
        if event.isDirectionInvertedFromDevice { d = -d }
        guard d != 0 else { return }
        let fine: Float = event.modifierFlags.contains(.option) ? 0.1 : 1
        if event.hasPreciseScrollingDeltas {
            // trackpad: ~400 px of swipe for the full range
            value = clamp(value + d * fine * range / 400)
        } else if spec.integer {
            value = clamp(value.rounded() + (d > 0 ? 1 : -1))
        } else {
            // mouse wheel: 1/50 of the range per notch
            value = clamp(value + d * fine * range / 50)
        }
    }

    func clamp(_ v: Float) -> Float { Swift.min(Swift.max(v, spec.min), spec.max) }

    /// One step of the random walk: the velocity follows noise (so the motion is smooth, not jittery),
    /// the value bounces off the ends of the range.
    func stepWalk(dt: Float, speed: Float) {
        guard walk, range > 0, speed > 0 else { return }
        let u1 = Float.random(in: Float.ulpOfOne...1), u2 = Float.random(in: 0...1)
        let gauss = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        walkVel += gauss * speed * dt.squareRoot() - walkVel * 1.5 * dt
        var v = value + walkVel * range * dt
        if v > spec.max { v = 2 * spec.max - v; walkVel = -abs(walkVel) }
        if v < spec.min { v = 2 * spec.min - v; walkVel = abs(walkVel) }
        value = clamp(v)
    }
}

@Observable
final class Module: Identifiable {
    let spec: ModuleSpec
    var enabled: Bool
    var expanded = false
    let params: [Param]
    /// Shared per-kind controls: colour & blend for generators, mix for effects.
    let common: [Param]

    var id: String { spec.id }

    init(_ spec: ModuleSpec) {
        precondition(spec.params.count <= 16, "\(spec.id): at most 16 params")
        self.spec = spec
        self.enabled = spec.enabled
        self.params = spec.params.map(Param.init)
        switch spec.kind {
        case .generator:
            self.common = [
                Param(.range("c.hue", "Hue", 0, 1, spec.hue)),
                Param(.range("c.sat", "Saturation", 0, 1, 0.75)),
                Param(.range("c.bright", "Brightness", 0, 2, 1)),
                Param(.range("c.gate", "Note gate", 0, 1, 0,
                             help: "0 = always visible, 1 = only lights up on MIDI notes")),
                Param(.choice("c.blend", "Blend", ["Add", "Screen", "Max", "Multiply"])),
            ]
        case .effect:
            self.common = [Param(.range("c.mix", "Mix", 0, 1, 1, help: "Dry / wet"))]
        case .master, .modulator, .palette:
            self.common = []
        }
    }

    var allParams: [Param] { params + common }

    func param(_ key: String) -> Param? { allParams.first { $0.spec.key == key } }

    /// The module's own params as the shader's `p[16]`, modulation applied.
    func packedParams(_ mods: [Float] = []) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        for (i, p) in params.enumerated() { out[i] = p.packed(mods) }
        return out
    }

    /// GenCommon / FxCommon (8 floats), modulation applied.
    func packedCommon(_ mods: [Float] = []) -> [Float] {
        var out = [Float](repeating: 0, count: 8)
        for (i, p) in common.enumerated() { out[i] = p.packed(mods) }
        return out
    }

    var blendIndex: Int { spec.kind == .generator ? Int(common[4].packed) : 0 }

    func randomize() {
        for p in params { p.randomize() }
        if spec.kind == .generator { common[0].randomize() }
    }

    func reset() { allParams.forEach { $0.reset() } }

    /// Params the group drift button toggles (option pickers and render settings would jump around).
    var walkable: [Param] {
        allParams.filter { $0.spec.options == nil && !["bpm", "decay"].contains($0.spec.key) }
    }

    var walking: Bool { walkable.contains { $0.walk } }

    func toggleWalk() {
        let on = !walking
        walkable.forEach { $0.walk = on }
    }
}

// MARK: - Presets

struct ModuleState: Codable {
    var enabled: Bool
    var values: [String: Float]
    var cc: [String: Int]
    var walk: [String]? = nil
    var mods: [String: ModRoute]? = nil
}

struct ModRoute: Codable {
    var source: String
    var depth: Float
}

struct Snapshot: Codable {
    var modules: [String: ModuleState]
    var effectOrder: [String]
    /// Custom palette stops (r, g, b).
    var customPalette: [[Float]]? = nil
}

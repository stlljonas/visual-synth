import AppKit
import Foundation
import Observation

// MARK: - Specs (static descriptions, see Generators.swift / Effects.swift)

enum ModuleKind: String, Codable {
    case generator, effect, master
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
}

// MARK: - Live state

@Observable
final class Param: Identifiable {
    let spec: ParamSpec
    var value: Float
    /// MIDI CC number mapped to this parameter (MIDI learn).
    var cc: Int?

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

    var display: String {
        if let options = spec.options {
            return options[Swift.min(Swift.max(Int(packed), 0), options.count - 1)]
        }
        if spec.integer { return "\(Int(packed))\(spec.unit)" }
        let v = value
        let digits = range >= 100 ? 0 : (range >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f", v) + spec.unit
    }

    func reset() { value = spec.def }

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
        case .master:
            self.common = []
        }
    }

    var allParams: [Param] { params + common }

    func param(_ key: String) -> Param? { allParams.first { $0.spec.key == key } }

    /// The module's own params as the shader's `p[16]`.
    var packedParams: [Float] {
        var out = [Float](repeating: 0, count: 16)
        for (i, p) in params.enumerated() { out[i] = p.packed }
        return out
    }

    /// GenCommon / FxCommon (8 floats).
    var packedCommon: [Float] {
        var out = [Float](repeating: 0, count: 8)
        for (i, p) in common.enumerated() { out[i] = p.packed }
        return out
    }

    var blendIndex: Int { spec.kind == .generator ? Int(common[4].packed) : 0 }

    func randomize() {
        for p in params { p.randomize() }
        if spec.kind == .generator { common[0].randomize() }
    }

    func reset() { allParams.forEach { $0.reset() } }
}

// MARK: - Presets

struct ModuleState: Codable {
    var enabled: Bool
    var values: [String: Float]
    var cc: [String: Int]
}

struct Snapshot: Codable {
    var modules: [String: ModuleState]
    var effectOrder: [String]
}

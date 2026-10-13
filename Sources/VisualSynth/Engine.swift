import Foundation
import Observation
import QuartzCore

/// Everything the renderer and the UI share: the modules and their params,
/// and the musical state that drives the shaders (`Globals`).
@Observable
final class Engine {
    let master: Module
    let generators: [Module]
    var effects: [Module]

    // UI state
    var showPanel = true
    var learning: Param?
    var midiDevices: [String] = []
    var fps: Double = 0
    var gpuMs: Double = 0
    var resolution = ""
    var shaderError: String?
    /// Bumped on every MIDI message (UI blinks on change).
    var midiActivity = 0
    var clockBPM: Double?

    // Audio from the Mac (Spotify, YouTube, …): see AudioInput.swift
    /// Listen to the Mac's audio and follow its beat when no MIDI clock is running.
    var audioEnabled = false { didSet { if audioEnabled != oldValue { onAudioEnabled?(audioEnabled) } } }
    /// Shown under the switch, e.g. "124 bpm · locked" or "Needs Screen & System Audio Recording permission".
    var audioStatus = ""
    /// Tempo currently driving the beat, for the header: "clock", "audio" or "manual".
    var tempoSource = "manual"
    @ObservationIgnored var onAudioEnabled: ((Bool) -> Void)?
    /// Smoothed band levels of the Mac's audio, 0…1 (written on the main thread by AudioInput).
    @ObservationIgnored var bass: Float = 0
    @ObservationIgnored var mid: Float = 0
    @ObservationIgnored var high: Float = 0
    @ObservationIgnored var level: Float = 0
    @ObservationIgnored private var audioBPM: Double = 0
    @ObservationIgnored private var audioBeatTime: CFTimeInterval = 0
    @ObservationIgnored private var audioConfidence: Double = 0
    @ObservationIgnored private var audioUpdated: CFTimeInterval = 0

    // Musical state, updated many times per second: kept out of observation.
    @ObservationIgnored var pulse: Float = 0
    @ObservationIgnored var gate: Float = 0
    @ObservationIgnored var note: Float = 0.5
    @ObservationIgnored var velocity: Float = 0
    @ObservationIgnored var trigger: Float = 0
    @ObservationIgnored var mod: Float = 0
    @ObservationIgnored var beat: Double = 0
    @ObservationIgnored var time: Double = 0
    @ObservationIgnored private var held = Set<Int>()
    @ObservationIgnored private var clockTicks = 0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var tickInterval: Double = 0

    init() {
        master = Module(ModuleSpec(id: "master", name: "Master", kind: .master, function: "", params: [
            .range("bpm", "Tempo", 40, 240, 120, unit: " bpm",
                   help: "Used when no MIDI clock is received"),
            .range("decay", "Note decay", 0.02, 2, 0.35, unit: " s",
                   help: "How long a note's pulse lasts"),
            .range("bright", "Brightness", 0, 2, 1),
            .range("contrast", "Contrast", 0.5, 2, 1),
            .choice("scale", "Render scale", ["100%", "75%", "50%"], 0,
                    help: "Lower if the frame rate drops"),
            .range("drift", "Drift speed", 0, 2, 0.4,
                   help: "How fast sliders with drift (↝) wander"),
        ], enabled: true))
        generators = Generators.all.map(Module.init)
        effects = (Effects.all + EffectsMore.all).map(Module.init)
    }

    var modules: [Module] { [master] + generators + effects }

    func module(_ id: String) -> Module? { modules.first { $0.id == id } }

    // MARK: Musical input

    func noteOn(_ n: Int, velocity v: Int) {
        held.insert(n)
        note = Float(n) / 127
        velocity = Float(v) / 127
        pulse = max(pulse, velocity)
        trigger += 1
    }

    func noteOff(_ n: Int) { held.remove(n) }

    func controlChange(_ cc: Int, value: Int) {
        if cc == 1 { mod = Float(value) / 127 }
        if let p = learning {
            for m in modules { for q in m.allParams where q.cc == cc { q.cc = nil } }
            p.cc = cc
            learning = nil
        }
        for m in modules {
            for p in m.allParams where p.cc == cc { p.normalized = Float(value) / 127 }
        }
    }

    func clockTick(at t: CFTimeInterval) {
        if lastTick > 0, t - lastTick < 0.5 {
            let dt = t - lastTick
            tickInterval = tickInterval == 0 ? dt : tickInterval * 0.9 + dt * 0.1
            clockTicks += 1
            // pull the free-running beat toward the clock
            beat += (Double(clockTicks) / 24 - beat) * 0.2
        } else {
            clockTicks = Int((beat * 24).rounded())
        }
        lastTick = t
    }

    func clockStart() {
        clockTicks = 0
        beat = 0
    }

    func midiSeen() { midiActivity &+= 1 }

    var clockActive: Bool { CACurrentMediaTime() - lastTick < 0.5 && tickInterval > 0 }

    /// Audio beat tracking result (call on the main thread, whenever the estimate updates).
    /// `beatTime`: a recent moment (CACurrentMediaTime) that was on a beat; `confidence` 0…1.
    func audioTempo(bpm: Double, beatTime: CFTimeInterval, confidence: Double) {
        audioBPM = bpm
        audioBeatTime = beatTime
        audioConfidence = confidence
        audioUpdated = CACurrentMediaTime()
    }

    var audioActive: Bool {
        audioEnabled && audioConfidence >= 0.4 && audioBPM > 0 && CACurrentMediaTime() - audioUpdated < 3
    }

    var currentBPM: Double {
        if clockActive { return 60 / (tickInterval * 24) }
        if audioActive { return audioBPM }
        return Double(master.param("bpm")!.value)
    }

    // MARK: Per frame

    /// Advance envelopes and the beat, and pack `Globals` for the shaders.
    func frame(dt: Double, size: (Double, Double)) -> [Float] {
        time += dt
        let bpm = currentBPM
        beat += dt * bpm / 60
        if !clockActive && audioActive {
            // phase-lock to the audio's beats: nudge toward the nearest beat grid position
            let target = (CACurrentMediaTime() - audioBeatTime) * audioBPM / 60
            var err = (target - beat).truncatingRemainder(dividingBy: 1)
            if err > 0.5 { err -= 1 } else if err < -0.5 { err += 1 }
            beat += err * min(1, dt * 4)
        }
        let drift = master.param("drift")!.value
        for m in modules {
            for p in m.allParams where p.walk { p.stepWalk(dt: Float(dt), speed: drift) }
        }
        let decay = Double(master.param("decay")!.value)
        pulse *= Float(exp(-dt / decay))
        let target: Float = held.isEmpty ? 0 : 1
        gate += (target - gate) * Float(min(1, dt * 30))

        return [
            Float(size.0), Float(size.1), Float(time.truncatingRemainder(dividingBy: 3600)), Float(dt),
            Float(size.0 / size.1), pulse, note, velocity,
            gate, trigger, Float(beat.truncatingRemainder(dividingBy: 4096)), Float(bpm),
            mod, bass, mid, high,
        ]
    }

    // MARK: Presets

    func snapshot() -> Snapshot {
        var mods: [String: ModuleState] = [:]
        for m in modules {
            var values: [String: Float] = [:], cc: [String: Int] = [:]
            for p in m.allParams {
                values[p.spec.key] = p.value
                if let c = p.cc { cc[p.spec.key] = c }
            }
            let walk = m.allParams.filter(\.walk).map(\.spec.key)
            mods[m.id] = ModuleState(enabled: m.enabled, values: values, cc: cc, walk: walk.isEmpty ? nil : walk)
        }
        return Snapshot(modules: mods, effectOrder: effects.map(\.id))
    }

    func apply(_ s: Snapshot) {
        for m in modules {
            guard let st = s.modules[m.id] else { continue }
            if m.spec.kind != .master { m.enabled = st.enabled }
            for p in m.allParams {
                if let v = st.values[p.spec.key] { p.value = p.clamp(v) }
                p.cc = st.cc[p.spec.key]
                p.walk = st.walk?.contains(p.spec.key) ?? false
            }
        }
        let order = s.effectOrder
        effects.sort { a, b in
            (order.firstIndex(of: a.id) ?? Int.max) < (order.firstIndex(of: b.id) ?? Int.max)
        }
    }

    func moveEffect(_ m: Module, by delta: Int) {
        guard let i = effects.firstIndex(where: { $0 === m }) else { return }
        let j = i + delta
        guard effects.indices.contains(j) else { return }
        effects.swapAt(i, j)
    }

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisualSynth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var presetsDir: URL {
        let dir = supportDir.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @ObservationIgnored private var lastSaved: Data?

    func save(to url: URL = Engine.supportDir.appendingPathComponent("state.json")) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot()) else { return }
        if url.lastPathComponent == "state.json" {
            if data == lastSaved { return }
            lastSaved = data
        }
        try? data.write(to: url, options: .atomic)
    }

    func load(from url: URL = Engine.supportDir.appendingPathComponent("state.json")) {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(s)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Command-line modes for checking shaders without opening a window:
///
///   VisualSynth --check                      compile all shaders and every module's pipeline
///   VisualSynth --render out.png [options]   render frames offscreen and save the last one
///   VisualSynth --bench [options]            GPU time per frame
///
/// options: --size 2560x1664   --frames 120   --only id,id,…  (enable exactly these modules)
///          --all (enable every module)       --set id.key=value,…   --notes (play a note every beat)
///          --mod id.key=source:depth,…  (e.g. spin.radius=lfo1:0.3; sources in Modulation.swift)
///          --frames-dir DIR (save every frame)  --bpm 120  --media FILE (image / video for the media layer)
enum Headless {
    static func run(_ args: [String]) -> Int32? {
        if args.contains("--profile") { return profile(args) }
        if args.contains("--selftest-scenes") { return sceneSelfTest() }
        guard args.contains(where: { ["--check", "--render", "--bench"].contains($0) }) else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let engine = Engine()
        guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return 1 }
        let r = Renderer(device: device, engine: engine)
        if let err = engine.shaderError { print("SHADER ERROR:\n\(err)"); return 1 }

        if args.contains("--check") {
            var bad = 0
            for m in engine.generators + engine.effects {
                let blends = m.spec.kind == .generator ? [1, 2, 3, 4] : [0]
                for b in blends where r.pipeline(m.spec.function, blend: b, format: r.canvasFormat) == nil {
                    print("FAIL \(m.id): \(engine.shaderError ?? "?")")
                    bad += 1
                    break
                }
                if m.spec.params.count > 16 { print("FAIL \(m.id): more than 16 params"); bad += 1 }
            }
            let ids = (engine.generators + engine.effects).map(\.id)
            if Set(ids).count != ids.count { print("FAIL duplicate module ids"); bad += 1 }
            print(bad == 0 ? "OK: \(engine.generators.count) generators, \(engine.effects.count) effects" : "\(bad) failed")
            return bad == 0 ? 0 : 1
        }

        let size = (value("--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.count == 2 ? size[0] : 1920, size.count == 2 ? size[1] : 1080)
        let frames = Int(value("--frames") ?? "") ?? (args.contains("--bench") ? 600 : 120)

        if let only = value("--only") {
            let ids = Set(only.split(separator: ",").map(String.init))
            for m in engine.generators + engine.effects + [engine.palette] { m.enabled = ids.contains(m.id) }
        }
        // --mod id.key=source:depth,…  route a slider to a modulator
        for kv in (value("--mod") ?? "").split(separator: ",") {
            let parts = kv.split(separator: "=")
            let path = parts.first?.split(separator: ".", maxSplits: 1) ?? []
            let route = parts.count == 2 ? parts[1].split(separator: ":") : []
            guard path.count == 2, route.count == 2, let d = Float(route[1]),
                  let p = engine.module(String(path[0]))?.param(String(path[1])) else {
                print("bad --mod \(kv)")
                continue
            }
            p.route(to: String(route[0]), depth: d)
        }
        if args.contains("--all") { for m in engine.generators + engine.effects { m.enabled = true } }
        for kv in (value("--set") ?? "").split(separator: ",") {
            let parts = kv.split(separator: "=")
            let path = parts.first?.split(separator: ".", maxSplits: 1) ?? []
            guard parts.count == 2, path.count == 2, let v = Float(parts[1]),
                  let p = engine.module(String(path[0]))?.param(String(path[1])) else {
                print("bad --set \(kv)")
                continue
            }
            p.value = p.clamp(v)
        }
        let notes = args.contains("--notes")
        // --frames-dir DIR: also save every frame as DIR/00000.png … (for videos)
        let framesDir = value("--frames-dir")
        if let dir = framesDir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        if let bpm = value("--bpm"), let v = Float(bpm) { engine.master.param("bpm")!.value = v }
        if let media = value("--media") {
            // a video needs the run loop to start playing: wait for its first frame
            engine.mediaPath = media
            let deadline = Date().addingTimeInterval(5)
            while engine.module("media")!.enabled, r.sources.frame(for: "media") == nil, Date() < deadline {
                r.sources.update(engine: engine)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            if r.sources.frame(for: "media") == nil { print("media: no frame (\(r.sources.state.mediaStatus))") }
        }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = device.makeTexture(descriptor: d)!

        let dt = 1.0 / 60
        var gpu: [Double] = []
        var lastBeat = -1
        let wall = Date()
        let lock = NSLock()
        for i in 0..<frames {
            if notes {
                let b = Int(engine.beat)
                if b != lastBeat {
                    lastBeat = b
                    engine.noteOn(48 + (b * 7) % 24, velocity: 110)
                }
                if engine.beat - Double(b) > 0.5 { engine.noteOff(48 + (b * 7) % 24) }   // held for half a beat
            }
            let cb = r.queue.makeCommandBuffer()!
            r.encode(into: target, cb: cb, dt: dt)
            if i >= 10 {
                cb.addCompletedHandler { cb in
                    lock.lock(); gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000); lock.unlock()
                }
            }
            cb.commit()
            // keep up to 3 frames in flight like the live app, so the GPU doesn't idle and clock down
            if let dir = framesDir {
                cb.waitUntilCompleted()
                _ = save(target, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%05d.png", i)))
            } else if i % 3 == 2 || i == frames - 1 {
                cb.waitUntilCompleted()
                if let e = cb.error { print("GPU error: \(e)"); return 1 }
            }
        }
        lock.lock(); lock.unlock()
        if let err = engine.shaderError { print("SHADER ERROR:\n\(err)"); return 1 }

        if args.contains("--bench") {
            let sorted = gpu.sorted()
            let mean = gpu.reduce(0, +) / Double(max(1, gpu.count))
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            let on = (engine.generators + engine.effects).filter(\.enabled).map(\.id).joined(separator: ",")
            // frames are pipelined, so wall time per frame is the real throughput
            let perFrame = Date().timeIntervalSince(wall) * 1000 / Double(frames)
            print(String(format: "%dx%d  %.2f ms/frame (%.0f fps max)  [per-buffer GPU span %.2f mean, %.2f p95]  modules: %@",
                         w, h, perFrame, 1000 / max(perFrame, 0.001), mean, p95, on))
        }
        if let out = value("--save-preset") {
            // the state after --only / --set / --mod, as a preset (enabled cards shown open)
            for m in engine.modules where m.enabled && m.spec.kind != .master { m.expanded = true }
            engine.save(to: URL(fileURLWithPath: out))
            print("saved \(out)")
        }
        if let out = value("--render") {
            guard save(target, to: URL(fileURLWithPath: out)) else { print("could not write \(out)"); return 1 }
            print("wrote \(out)")
        }
        return 0
    }

    /// --profile [--size WxH] [--frames N]: time every layer and effect on its own (effects on top of
    /// Scrolling Bars), each as the difference to its baseline, by re-running this binary with --bench.
    static func profile(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let size = value("--size") ?? "2560x1664", frames = value("--frames") ?? "400"
        let exe = CommandLine.arguments[0]
        func bench(_ only: String) -> Double {
            var best = Double.infinity
            for _ in 0..<2 {   // best of two: the GPU is shared with whatever else runs
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["--bench", "--only", only, "--size", size, "--frames", frames]
                let pipe = Pipe()
                p.standardOutput = pipe
                try? p.run()
                p.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if let r = out.range(of: #"([0-9.]+) ms/frame"#, options: .regularExpression),
                   let v = Double(out[r].split(separator: " ")[0]) { best = min(best, v) }
            }
            return best
        }
        let engine = Engine()
        let empty = bench("none"), bars = bench("bars")
        print(String(format: "%@  empty frame %.2f ms, bars %.2f ms", size, empty, bars))
        var rows: [(String, Double)] = []
        for m in engine.generators where m.id != "bars" { rows.append(("layer  " + m.id, bench(m.id) - empty)) }
        rows.append(("layer  bars", bars - empty))
        for m in engine.effects { rows.append(("effect " + m.id, bench("bars," + m.id) - bars)) }
        for (name, ms) in rows.sorted(by: { $0.1 > $1.1 }) {
            print(String(format: "%-22@ %+6.2f ms", name, ms))
        }
        return 0
    }

    /// --selftest-scenes (run with VISUALSYNTH_HOME=<empty dir>): save two scenes, crossfade between them, check values.
    static func sceneSelfTest() -> Int32 {
        let engine = Engine()
        guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
        let r = Renderer(device: device, engine: engine)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 400, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let target = device.makeTexture(descriptor: d)!
        func frames(_ n: Int, dt: Double = 1.0 / 60) {
            for _ in 0..<n {
                let cb = r.queue.makeCommandBuffer()!
                r.encode(into: target, cb: cb, dt: dt)
                cb.commit()
                cb.waitUntilCompleted()
            }
        }
        let lib = SceneLibrary(engine: engine)
        lib.thumbnailProvider = { r.thumbnailPNG() }
        var fails = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { fails += 1 } }
        let spin = engine.module("spin")!, bars = engine.module("bars")!
        // scene A: spin only, radius 0.3
        bars.enabled = false; spin.enabled = true; spin.param("radius")!.value = 0.3
        frames(10)
        lib.saveNew(name: "A")
        // scene B: bars only, spin off, radius 0.9
        bars.enabled = true; spin.enabled = false; spin.param("radius")!.value = 0.9
        frames(10)
        lib.saveNew(name: "B")
        check(lib.entries.map(\.name) == ["A", "B"], "two scenes saved in order: \(lib.entries.map(\.name))")
        check(lib.entries.allSatisfy { $0.thumbnail != nil }, "thumbnails stored")
        // switch to A with a 1 s fade
        engine.master.param("scenefade")!.value = 1
        lib.load(index: 0)
        check(spin.enabled && bars.enabled, "during fade: spin fading in, bars still on fading out")
        frames(30)   // 0.5 s
        let mid = spin.param("radius")!.value
        check(mid > 0.31 && mid < 0.89, "radius halfway: \(mid)")
        let bBright = bars.common[2].value
        check(bBright > 0.01 && bBright < 0.99, "bars brightness fading out: \(bBright)")
        frames(40)   // past 1 s
        check(abs(spin.param("radius")!.value - 0.3) < 1e-4, "radius arrived at 0.3")
        check(!bars.enabled && abs(bars.common[2].value - 1) < 1e-4, "bars off, its brightness restored for next time")
        check(spin.enabled && abs(spin.common[2].value - 1) < 1e-4, "spin on at full brightness")
        // rename, numbering stays
        lib.rename(lib.entries[0], to: "Orbit")
        check(lib.entries.map(\.name) == ["Orbit", "B"], "rename keeps the number: \(lib.entries.map(\.name))")
        // instant load
        engine.master.param("scenefade")!.value = 0
        lib.load(index: 1)
        check(bars.enabled && !spin.enabled, "instant switch to B")
        print(fails == 0 ? "ALL OK" : "\(fails) failed")
        return fails == 0 ? 0 : 1
    }

    static func save(_ t: MTLTexture, to url: URL) -> Bool {
        let bpr = t.width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * t.height)
        t.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: t.width, height: t.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}

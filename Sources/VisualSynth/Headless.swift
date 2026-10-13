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
enum Headless {
    static func run(_ args: [String]) -> Int32? {
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
            for m in engine.generators + engine.effects { m.enabled = ids.contains(m.id) }
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

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = device.makeTexture(descriptor: d)!

        let dt = 1.0 / 60
        var gpu: [Double] = []
        var lastBeat = -1
        let wall = Date()
        for i in 0..<frames {
            if notes {
                let b = Int(engine.beat)
                if b != lastBeat {
                    lastBeat = b
                    engine.noteOn(48 + (b * 7) % 24, velocity: 110)
                    engine.noteOff(48 + (b * 7) % 24)
                }
            }
            let cb = r.queue.makeCommandBuffer()!
            r.encode(into: target, cb: cb, dt: dt)
            cb.commit()
            cb.waitUntilCompleted()
            if let e = cb.error { print("GPU error: \(e)"); return 1 }
            if i >= 10 { gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        if let err = engine.shaderError { print("SHADER ERROR:\n\(err)"); return 1 }

        if args.contains("--bench") {
            let sorted = gpu.sorted()
            let mean = gpu.reduce(0, +) / Double(max(1, gpu.count))
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            let on = (engine.generators + engine.effects).filter(\.enabled).map(\.id).joined(separator: ",")
            print(String(format: "%dx%d  GPU %.2f ms/frame mean, %.2f ms p95  (%.0f fps GPU-bound)  wall %.1fs  modules: %@",
                         w, h, mean, p95, 1000 / max(mean, 0.001), Date().timeIntervalSince(wall), on))
        }
        if let out = value("--render") {
            guard save(target, to: URL(fileURLWithPath: out)) else { print("could not write \(out)"); return 1 }
            print("wrote \(out)")
        }
        return 0
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

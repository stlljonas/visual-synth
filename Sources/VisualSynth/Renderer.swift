import Foundation
import Metal
import MetalKit
import QuartzCore

/// Finds the shader sources: inside the .app (Contents/Resources/Shaders), else the
/// source folder this file was compiled from (so `swift run` picks up edits live).
enum ShaderSource {
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["VISUALSYNTH_SHADERS"] {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Shaders"),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Shaders")
    }

    static var files: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "metal" }.sorted { a, b in
            if a.lastPathComponent == "Common.metal" { return true }
            if b.lastPathComponent == "Common.metal" { return false }
            return a.lastPathComponent < b.lastPathComponent
        }
    }

    static func load() -> String {
        files.map { (try? String(contentsOf: $0)) ?? "" }.joined(separator: "\n")
    }

    static var lastModified: Date {
        files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let engine: Engine
    let canvasFormat: MTLPixelFormat = .rgba16Float

    private var library: MTLLibrary?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var failed: Set<String> = []
    private var canvas: [MTLTexture] = []
    /// Which canvas holds last frame's final image (feedback effects read it as `prev`).
    /// Three canvases rotate, so keeping the frame costs nothing (no copy).
    private var historyIndex = 2
    /// One view per mip level of each canvas texture, for the downsample chain.
    private var levelViews: [[MTLTexture]] = []
    static let mipLevels = 8
    private var shaderStamp = Date.distantPast
    private var lastCheck: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var statsT: CFTimeInterval = 0
    private var frameCount = 0
    private var gpuAccum: Double = 0
    private var gpuSamples = 0
    /// Render scale chosen by "Auto": drops while the GPU can't keep up, climbs back when it can.
    private(set) var autoScale: Double = 1
    private var gpuEMA: Double = 0
    private var lastScaleChange: CFTimeInterval = 0
    private var frameBudgetMs: Double = 1000.0 / 60

    init(device: MTLDevice, engine: Engine) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.engine = engine
        super.init()
        reloadShaders()
    }

    // MARK: Shaders

    /// Compile all shaders. Returns the error text, or nil. Keeps the old library on failure.
    @discardableResult
    func reloadShaders() -> String? {
        shaderStamp = ShaderSource.lastModified
        do {
            let opts = MTLCompileOptions()
            opts.fastMathEnabled = true
            library = try device.makeLibrary(source: ShaderSource.load(), options: opts)
            pipelines = [:]
            failed = []
            engine.shaderError = nil
            return nil
        } catch {
            let text = "\(error)"
            // keep only the error lines, not the warnings
            let lines = text.split(separator: "\n").filter { $0.contains("error") }
            engine.shaderError = lines.isEmpty ? text : lines.joined(separator: "\n")
            return engine.shaderError
        }
    }

    private func checkShaderEdits() {
        let now = CACurrentMediaTime()
        guard now - lastCheck > 0.5 else { return }
        lastCheck = now
        if ShaderSource.lastModified > shaderStamp { reloadShaders() }
    }

    /// blend: 0 none, 1 add, 2 screen, 3 max, 4 multiply
    func pipeline(_ function: String, blend: Int, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(function)|\(blend)|\(format.rawValue)"
        if let p = pipelines[key] { return p }
        if failed.contains(key) { return nil }
        guard let lib = library else { return nil }
        guard let frag = lib.makeFunction(name: function), let vert = lib.makeFunction(name: "vs_full") else {
            failed.insert(key)
            engine.shaderError = "missing shader function \(function)"
            return nil
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vert
        d.fragmentFunction = frag
        let att = d.colorAttachments[0]!
        att.pixelFormat = format
        if blend > 0 {
            att.isBlendingEnabled = true
            att.alphaBlendOperation = .max
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
            switch blend {
            case 1:
                att.rgbBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .one
            case 2:
                att.rgbBlendOperation = .add
                att.sourceRGBBlendFactor = .oneMinusDestinationColor
                att.destinationRGBBlendFactor = .one
            case 3:
                att.rgbBlendOperation = .max
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .one
            default:
                att.rgbBlendOperation = .add
                att.sourceRGBBlendFactor = .destinationColor
                att.destinationRGBBlendFactor = .zero
            }
        }
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            pipelines[key] = p
            return p
        } catch {
            failed.insert(key)
            engine.shaderError = "\(function): \(error)"
            return nil
        }
    }

    // MARK: Targets

    private func ensureTargets(width: Int, height: Int) {
        if let t = canvas.first, t.width == width, t.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: canvasFormat, width: width, height: height,
                                                         mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        d.mipmapLevelCount = min(Renderer.mipLevels, d.mipmapLevelCount)
        canvas = (0..<3).map { _ in device.makeTexture(descriptor: d)! }
        levelViews = canvas.map { t in
            (0..<t.mipmapLevelCount).map {
                t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)!
            }
        }
        historyIndex = 2
        // start from black
        if let cb = queue.makeCommandBuffer() {
            for t in canvas { clear(t, cb) }
            cb.commit()
        }
    }

    private func clear(_ t: MTLTexture, _ cb: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    // MARK: Frame

    /// Encode one frame into `target` (the drawable or an offscreen texture).
    func encode(into target: MTLTexture, cb: MTLCommandBuffer, dt: Double) {
        let option = Int(engine.master.param("scale")!.packed)
        let scale: Double = option >= 3 ? autoScale : [1.0, 0.75, 0.5][option]
        let w = max(1, Int(Double(target.width) * scale)), h = max(1, Int(Double(target.height) * scale))
        ensureTargets(width: w, height: h)
        var globals = engine.frame(dt: dt, size: (Double(w), Double(h)))
        let gSize = globals.count * MemoryLayout<Float>.stride

        func pass(_ texture: MTLTexture, clear: Bool, _ body: (MTLRenderCommandEncoder) -> Void) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = texture
            rp.colorAttachments[0].loadAction = clear ? .clear : .dontCare
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            enc.setVertexBytes(&globals, length: gSize, index: 0)
            enc.setFragmentBytes(&globals, length: gSize, index: 0)
            body(enc)
            enc.endEncoding()
        }

        func bind(_ enc: MTLRenderCommandEncoder, _ m: Module) {
            var p = m.packedParams(engine.modValues), c = m.packedCommon(engine.modValues)
            enc.setFragmentBytes(&p, length: p.count * 4, index: 1)
            enc.setFragmentBytes(&c, length: c.count * 4, index: 2)
        }

        // 1. generators, blended into one of the two canvases that don't hold last frame
        let history = canvas[historyIndex]
        let work = (0..<3).filter { $0 != historyIndex }
        var cur = work[0]
        pass(canvas[cur], clear: true) { enc in
            for m in engine.generators where m.enabled {
                guard let ps = pipeline(m.spec.function, blend: m.blendIndex + 1, format: canvasFormat) else { continue }
                enc.setRenderPipelineState(ps)
                bind(enc, m)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        // 2. effects, ping-pong
        for m in engine.effects where m.enabled {
            guard let ps = pipeline(m.spec.function, blend: 0, format: canvasFormat) else { continue }
            let next = cur == work[0] ? work[1] : work[0]
            let src = canvas[cur], dst = canvas[next]
            if m.spec.mips, let down = pipeline("downsample", blend: 0, format: canvasFormat) {
                // own mip chain: each level is a 2×2 box of the one above (much cheaper than generateMipmaps)
                let views = levelViews[cur]
                for level in 1..<views.count {
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = src
                    rp.colorAttachments[0].level = level
                    rp.colorAttachments[0].loadAction = .dontCare
                    rp.colorAttachments[0].storeAction = .store
                    guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { break }
                    enc.setRenderPipelineState(down)
                    enc.setVertexBytes(&globals, length: gSize, index: 0)
                    enc.setFragmentTexture(views[level - 1], index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
            pass(dst, clear: false) { enc in
                enc.setRenderPipelineState(ps)
                bind(enc, m)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentTexture(history, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            cur = next
        }

        // 3. this frame becomes next frame's `prev`
        historyIndex = cur

        // 4. present
        if let ps = pipeline("present", blend: 0, format: target.pixelFormat) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(ps)
                enc.setVertexBytes(&globals, length: gSize, index: 0)
                var p = engine.master.packedParams(engine.modValues)
                enc.setFragmentBytes(&p, length: p.count * 4, index: 1)
                enc.setFragmentTexture(canvas[cur], index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// A small PNG of the last frame (for scene thumbnails), at most `maxWidth` pixels wide.
    func thumbnailPNG(maxWidth: Int = 320) -> Data? {
        guard canvas.count == 3, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        let t = canvas[historyIndex]
        let bpr = t.width * 8   // rgba16Float
        guard let buf = device.makeBuffer(length: bpr * t.height, options: .storageModeShared) else { return nil }
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * t.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let step = max(1, t.width / maxWidth)
        let w = t.width / step, h = t.height / step
        let src = buf.contents().bindMemory(to: Float16.self, capacity: t.width * t.height * 4)
        let p = engine.master.packedParams()
        let bright = p[2], contrast = p[3]
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = ((y * step) * t.width + x * step) * 4, o = (y * w + x) * 4
                for c in 0..<3 {
                    let v = (Float(src[i + c]) * bright - 0.5) * contrast + 0.5   // like the present pass
                    out[o + c] = UInt8(max(0, min(255, v * 255)))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    private func gpuDone(_ ms: Double) {
        gpuAccum += ms
        gpuSamples += 1
        gpuEMA = gpuEMA == 0 ? ms : gpuEMA * 0.9 + ms * 0.1
        // Auto render scale, in steps of 1/8 with hysteresis (each change reallocates the canvases)
        let now = CACurrentMediaTime()
        guard Int(engine.master.param("scale")!.packed) >= 3, now - lastScaleChange > 1 else { return }
        if gpuEMA > frameBudgetMs * 0.85, autoScale > 0.5 {
            autoScale -= 0.125
            lastScaleChange = now
            gpuEMA *= 0.75
        } else if autoScale < 1 {
            let next = autoScale + 0.125
            let predicted = gpuEMA * (next * next) / (autoScale * autoScale)
            if predicted < frameBudgetMs * 0.6 {
                autoScale = next
                lastScaleChange = now
                gpuEMA = predicted
            }
        }
    }

    func draw(in view: MTKView) {
        checkShaderEdits()
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, now - lastFrame)
        lastFrame = now
        engine.frameHistory.append((now, dt, gpuEMA))
        if let first = engine.frameHistory.first, now - first.t > 10.5 {
            engine.frameHistory.removeFirst(min(engine.frameHistory.count, 64))
        }
        engine.displayHz = Double(view.preferredFramesPerSecond)
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, cb: cb, dt: dt)
        frameBudgetMs = 1000.0 / Double(max(30, view.preferredFramesPerSecond))
        cb.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.gpuDone(ms) }
        }
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        if now - statsT >= 0.5 {
            engine.fps = Double(frameCount) / (now - statsT)
            engine.gpuMs = gpuSamples > 0 ? gpuAccum / Double(gpuSamples) : 0
            let option = Int(engine.master.param("scale")!.packed)
            let shownScale = option >= 3 ? autoScale : [1.0, 0.75, 0.5][option]
            engine.resolution = "\(drawable.texture.width)×\(drawable.texture.height)"
                + (shownScale < 1 ? " @\(Int(shownScale * 100))%" : "")
            let src = engine.clockActive ? "clock" : (engine.audioActive ? "audio" : "manual")
            let shown: Double? = src == "manual" ? nil : engine.currentBPM.rounded()
            if engine.clockBPM != shown { engine.clockBPM = shown }
            if engine.tempoSource != src { engine.tempoSource = src }
            frameCount = 0
            gpuAccum = 0
            gpuSamples = 0
            statsT = now
        }
    }
}

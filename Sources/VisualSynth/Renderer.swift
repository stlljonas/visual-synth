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
    private var history: MTLTexture?
    private var shaderStamp = Date.distantPast
    private var lastCheck: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var statsT: CFTimeInterval = 0
    private var frameCount = 0
    private var gpuAccum: Double = 0
    private var gpuSamples = 0

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
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        canvas = (0..<2).map { _ in device.makeTexture(descriptor: d)! }
        history = device.makeTexture(descriptor: d)!
        // start from black
        if let cb = queue.makeCommandBuffer() {
            for t in canvas + [history!] { clear(t, cb) }
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
        let scale: Double = [1.0, 0.75, 0.5][min(2, Int(engine.master.param("scale")!.packed))]
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
            var p = m.packedParams, c = m.packedCommon
            enc.setFragmentBytes(&p, length: p.count * 4, index: 1)
            enc.setFragmentBytes(&c, length: c.count * 4, index: 2)
        }

        // 1. generators, blended into canvas[0]
        var cur = 0
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
            let src = canvas[cur], dst = canvas[1 - cur]
            pass(dst, clear: false) { enc in
                enc.setRenderPipelineState(ps)
                bind(enc, m)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentTexture(history, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            cur = 1 - cur
        }

        // 3. keep this frame for feedback effects
        if let blit = cb.makeBlitCommandEncoder(), let history {
            blit.copy(from: canvas[cur], to: history)
            blit.endEncoding()
        }

        // 4. present
        if let ps = pipeline("present", blend: 0, format: target.pixelFormat) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(ps)
                enc.setVertexBytes(&globals, length: gSize, index: 0)
                var p = engine.master.packedParams
                enc.setFragmentBytes(&p, length: p.count * 4, index: 1)
                enc.setFragmentTexture(canvas[cur], index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        checkShaderEdits()
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, now - lastFrame)
        lastFrame = now
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, cb: cb, dt: dt)
        cb.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.gpuAccum += ms; self?.gpuSamples += 1 }
        }
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        if now - statsT >= 0.5 {
            engine.fps = Double(frameCount) / (now - statsT)
            engine.gpuMs = gpuSamples > 0 ? gpuAccum / Double(gpuSamples) : 0
            engine.resolution = "\(drawable.texture.width)×\(drawable.texture.height)"
            let clock = engine.clockActive ? engine.currentBPM.rounded() : nil
            if engine.clockBPM != clock { engine.clockBPM = clock }
            frameCount = 0
            gpuAccum = 0
            gpuSamples = 0
            statsT = now
        }
    }
}

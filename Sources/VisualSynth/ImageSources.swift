import AVFoundation
import CoreVideo
import Foundation
import Metal
import MetalKit
import Observation
import QuartzCore

/// Camera and image / video files as textures for the Camera and Image / Video layers.
/// Frames arrive as CVPixelBuffers and are wrapped as Metal textures without a copy (CVMetalTextureCache).

/// A frame the GPU may still be reading: keep `owner` alive until the command buffer completes.
struct SourceFrame {
    let texture: MTLTexture
    let owner: AnyObject?
}

private func makeTextureCache(_ device: MTLDevice) -> CVMetalTextureCache? {
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    return cache
}

/// Wrap a BGRA pixel buffer as a texture (shares its memory).
private func wrap(_ pb: CVPixelBuffer, _ cache: CVMetalTextureCache) -> SourceFrame? {
    var cvTex: CVMetalTexture?
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
          let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
    return SourceFrame(texture: tex, owner: cvTex)
}

// MARK: - Camera

/// What the Camera and Image / Video cards show.
@Observable
final class SourcesState {
    struct Device: Identifiable, Hashable { let id: String; let name: String }
    var devices: [Device] = []
    /// Chosen camera (unique id), kept across launches; nil = the first one.
    var selected: String? = UserDefaults.standard.string(forKey: "camera") {
        didSet { UserDefaults.standard.set(selected, forKey: "camera") }
    }
    /// e.g. "1920×1080 · 30 fps", or what's wrong.
    var status = ""
    /// File name and size of the image / video, or what's wrong.
    var mediaStatus = ""
}

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let state: SourcesState
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera", qos: .userInteractive)
    private let cache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: SourceFrame?
    private var running = false
    private var currentID: String?
    private var frames = 0
    private var rateT = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []

    init(device: MTLDevice, state: SourcesState) {
        cache = makeTextureCache(device)
        self.state = state
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true   // always the newest frame: lowest latency
        output.setSampleBufferDelegate(self, queue: queue)
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
                if self?.running == true { self?.restart() }
            })
        }
        refreshDevices()
    }

    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func refreshDevices() {
        state.devices = CameraSource.discover().map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Run the camera only while its layer is on (the green light goes off with it).
    func setActive(_ on: Bool) {
        if on {
            if !running || currentID != wantedID { start() }
        } else if running {
            stop()
        }
    }

    private var wantedID: String? {
        let ids = state.devices.map(\.id)
        if let s = state.selected, ids.contains(s) { return s }
        return ids.first
    }

    func select(_ id: String) {
        state.selected = id
        if running { restart() }
    }

    private func restart() {
        stop()
        start()
    }

    private func start() {
        running = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            state.status = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    guard self.running else { return }
                    if ok { self.start() } else { self.state.status = Self.denied }
                }
            }
            return
        default:
            state.status = Self.denied
            return
        }
        refreshDevices()
        guard let id = wantedID, let dev = AVCaptureDevice(uniqueID: id) else {
            state.status = "No camera found: plug one in, or use an iPhone (Continuity Camera)"
            return
        }
        currentID = id
        let name = dev.localizedName
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.sessionPreset = .high
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                if session.canAddInput(input) { session.addInput(input) }
                if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
                Self.pickFormat(dev)
                session.commitConfiguration()
                session.startRunning()
                let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
                let fps = dev.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                DispatchQueue.main.async {
                    self.state.status = "\(dims.width)×\(dims.height) · up to \(Int(fps.rounded())) fps"
                }
            } catch {
                session.commitConfiguration()
                DispatchQueue.main.async { self.state.status = "\(name): \(error.localizedDescription)" }
            }
        }
    }

    private static let denied = "No camera access: allow Visual Synth in System Settings › Privacy & Security › Camera"

    /// The highest frame rate the camera has at up to 1920 wide (smooth beats sharp; 1080p is plenty under effects).
    private static func pickFormat(_ dev: AVCaptureDevice) {
        func score(_ f: AVCaptureDevice.Format) -> (Double, Int32) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return (min(fps, 60), d.width <= 1920 ? d.width : 0)
        }
        guard let best = dev.formats.max(by: { score($0) < score($1) }), (try? dev.lockForConfiguration()) != nil else { return }
        dev.activeFormat = best
        if let r = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            dev.activeVideoMinFrameDuration = r.minFrameDuration
        }
        dev.unlockForConfiguration()
    }

    private func stop() {
        running = false
        currentID = nil
        queue.async { [self] in
            session.stopRunning()
            lock.lock(); latest = nil; lock.unlock()
        }
        state.status = ""
    }

    /// The newest camera frame, or nil before the first one.
    func frame() -> SourceFrame? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cache, let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let f = wrap(pb, cache) else { return }
        lock.lock(); latest = f; lock.unlock()
        // measured frame rate in the status line, every 2 s
        frames += 1
        let now = CACurrentMediaTime()
        if now - rateT >= 2 {
            let fps = Double(frames) / (now - rateT)
            frames = 0
            rateT = now
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            DispatchQueue.main.async {
                guard self.running else { return }
                self.state.status = "\(w)×\(h) · \(Int(fps.rounded())) fps"
            }
        }
    }
}

// MARK: - Image / video file

final class MediaSource {
    /// Shown in the card: file name and size, or what went wrong.
    private(set) var status = ""
    private let device: MTLDevice
    private let cache: CVMetalTextureCache?
    private var loadedPath: String?
    private var still: MTLTexture?
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?
    private var videoOut: AVPlayerItemVideoOutput?
    private var latest: SourceFrame?
    private var rate: Float = 1
    private var active = false

    static let imageTypes = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"]
    static let videoTypes = ["mov", "mp4", "m4v"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageTypes.contains(ext) || videoTypes.contains(ext)
    }

    init(device: MTLDevice) {
        self.device = device
        cache = makeTextureCache(device)
    }

    /// Called every frame: (re)load when the path changes, play only while the layer is on.
    func update(path: String?, on: Bool, rate: Float) -> String {
        if path != loadedPath { load(path) }
        if on != active || (on && rate != self.rate) {
            active = on
            self.rate = rate
            player?.rate = on ? rate : 0
        }
        return status
    }

    private func load(_ path: String?) {
        loadedPath = path
        still = nil; latest = nil
        player?.pause(); player = nil; videoOut = nil
        if let o = loopObserver { NotificationCenter.default.removeObserver(o); loopObserver = nil }
        active = false
        guard let path else { status = "Open an image or video, or drop one on the picture"; return }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else { status = "Missing: \(name)"; return }
        if MediaSource.videoTypes.contains(url.pathExtension.lowercased()) {
            let item = AVPlayerItem(url: url)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true])
            item.add(out)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.actionAtItemEnd = .none
            loopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                guard let self, let p = self.player else { return }
                p.seek(to: .zero)
                p.rate = self.active ? self.rate : 0
            }
            videoOut = out
            player = p
            status = name
        } else {
            let loader = MTKTextureLoader(device: device)
            do {
                let t = try loader.newTexture(URL: url, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                                                                  .textureStorageMode: MTLStorageMode.private.rawValue,
                                                                  .generateMipmaps: false])
                still = t
                status = "\(name) · \(t.width)×\(t.height)"
            } catch {
                status = "\(name): can't read (\(error.localizedDescription))"
            }
        }
    }

    func frame() -> SourceFrame? {
        if let still { return SourceFrame(texture: still, owner: nil) }
        guard let out = videoOut, let cache else { return nil }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
           let f = wrap(pb, cache) {
            latest = f
            if status.contains("×") == false {
                status += " · \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))"
            }
        }
        return latest
    }
}

// MARK: - Both, for the renderer and the panel

final class ImageSources {
    let state = SourcesState()
    let camera: CameraSource
    let media: MediaSource

    init(device: MTLDevice) {
        camera = CameraSource(device: device, state: state)
        media = MediaSource(device: device)
    }

    /// Once per frame, before drawing: start / stop the camera and the video with their layers.
    func update(engine: Engine) {
        if let cam = engine.module("camera") { camera.setActive(cam.enabled) }
        if let m = engine.module("media") {
            let status = media.update(path: engine.mediaPath, on: m.enabled, rate: m.param("rate")?.value ?? 1)
            if status != state.mediaStatus { state.mediaStatus = status }
        }
    }

    /// The texture a layer draws, if it has one.
    func frame(for id: String) -> SourceFrame? {
        switch id {
        case "camera": return camera.frame()
        case "media": return media.frame()
        default: return nil
        }
    }
}

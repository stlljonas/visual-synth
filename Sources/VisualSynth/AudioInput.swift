import Accelerate
import CoreAudio
import Foundation
import QuartzCore

/// Listens to the Mac's own audio output (Spotify, YouTube, …) and feeds the engine:
/// beat tracking → `engine.audioTempo(bpm:beatTime:confidence:)`, band levels → `engine.bass/mid/high/level`.
/// Started and stopped by the "Sync to Mac audio" switch (`engine.audioEnabled`).
///
/// Capture is a Core Audio process tap (`SystemAudioTap`, macOS 14.2+); the DSP is `BeatTracker`,
/// run on the tap's background queue. A 60 Hz main-thread timer copies the results into the engine.
///
/// Set `VISUALSYNTH_AUDIO_OFFSET_MS` to nudge the visual beat later (+) or earlier (−) if it
/// doesn't sit on the audible beat with your speakers; `VISUALSYNTH_DEBUG` logs the state every 2 s;
/// `VISUALSYNTH_AUDIO_SYNC=1` switches sync on at launch.
final class AudioInput {
    private let engine: Engine
    private let queue = DispatchQueue(label: "visualsynth.audio", qos: .userInteractive)

    // main thread
    private var tap: AnyObject?            // SystemAudioTap (macOS 14.2+)
    private var timer: Timer?
    private var debugTimer: Timer?
    private var startedAt: CFTimeInterval = 0
    private var startError: String?
    private var lastSerial = -1
    private var sentConfidence = 0.0
    private var lastStatusUpdate: CFTimeInterval = 0
    private var outputLatency: Double = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?

    // shared between the audio queue and main, under `lock`
    private let lock = NSLock()
    private var shared = Shared()
    private struct Shared {
        var levels = BeatTracker.Levels()
        var tempo: BeatTracker.Tempo?
        var serial = 0
        var silentFor: Double = 0
        var buffers = 0
        var heardSound = false
        var peak: Float = 0
        var lastBuffer: CFTimeInterval = 0
    }

    // audio queue only
    private var tracker: BeatTracker?

    /// Visuals are seen about a frame and a half after `Engine.frame()` computes them.
    private static let displayLatency = 0.020
    private static let userOffset = (ProcessInfo.processInfo.environment["VISUALSYNTH_AUDIO_OFFSET_MS"]
        .flatMap(Double.init) ?? 0) / 1000

    init(engine: Engine) {
        self.engine = engine
        // VISUALSYNTH_AUDIO_SYNC=1: switch sync on at launch (testing without clicking the panel)
        if ProcessInfo.processInfo.environment["VISUALSYNTH_AUDIO_SYNC"] == "1" {
            DispatchQueue.main.async { engine.audioEnabled = true }
        }
    }

    deinit { stop() }

    // MARK: Start / stop (main thread)

    func start() {
        stop()
        startedAt = CACurrentMediaTime()
        startError = nil
        lastSerial = -1
        lock.withLock { shared = Shared() }
        engine.audioStatus = "Starting…"

        guard #available(macOS 14.2, *) else {
            startError = "Needs macOS 14.2 or later"
            engine.audioStatus = startError!
            return
        }
        Self.permissionChecked = -10
        if Self.permission == .denied {
            startError = Self.permissionMessage
        } else {
            startCapture()
        }
        listenForDeviceChanges()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if ProcessInfo.processInfo.environment["VISUALSYNTH_DEBUG"] != nil {
            debugTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.logState() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        debugTimer?.invalidate(); debugTimer = nil
        stopCapture()
        stopListeningForDeviceChanges()
        engine.bass = 0; engine.mid = 0; engine.high = 0; engine.level = 0
        if engine.audioStatus != "" { engine.audioStatus = "" }
    }

    @available(macOS 14.2, *)
    private func makeTap() -> SystemAudioTap {
        SystemAudioTap(queue: queue) { [weak self] samples, sampleRate, hostTime in
            self?.process(samples, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    private func startCapture() {
        guard #available(macOS 14.2, *) else { return }
        let tap = makeTap()
        do {
            try tap.start()
            self.tap = tap
            outputLatency = tap.outputLatency
        } catch {
            startError = "Couldn't capture the Mac's audio: \(error)"
            NSLog("AudioInput: \(error)")
        }
    }

    private func stopCapture() {
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { tap.stop() }
        tap = nil
        queue.sync { tracker = nil }
    }

    /// The tap is tied to the output device it was created with (clock + latency): follow changes.
    private func listenForDeviceChanges() {
        var addr = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // creating our own (private) aggregate device also fires this: only restart on a real change
            guard let self, self.timer != nil, self.startError == nil, #available(macOS 14.2, *) else { return }
            let current = SystemAudioTap.defaultOutputDevice()
            guard let tap = self.tap as? SystemAudioTap, current != nil, current != tap.outputDevice else { return }
            self.stopCapture()
            self.startCapture()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            deviceListener = block
        }
    }

    private func stopListeningForDeviceChanges() {
        guard let block = deviceListener else { return }
        var addr = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        deviceListener = nil
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    // MARK: Audio queue

    private func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, hostTime: Double) {
        if tracker?.sampleRate != sampleRate { tracker = BeatTracker(sampleRate: sampleRate) }
        guard let tracker, let base = samples.baseAddress else { return }
        tracker.process(samples, hostTime: hostTime)
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        lock.withLock {
            shared.levels = tracker.levels
            if tracker.tempoSerial != shared.serial {
                shared.serial = tracker.tempoSerial
                shared.tempo = tracker.tempo
            }
            shared.silentFor = tracker.silent ? tracker.silentFor : 0
            shared.buffers += 1
            shared.lastBuffer = CACurrentMediaTime()
            shared.peak = max(peak, shared.peak * 0.99)
            if peak > 1e-4 { shared.heardSound = true }
        }
    }

    // MARK: Main thread

    private func tick() {
        let s = lock.withLock { shared }
        let now = CACurrentMediaTime()
        // the tap only runs while something is playing: no buffers = silence
        let stalled = now - s.lastBuffer > 0.4
        if stalled {
            engine.bass *= 0.85; engine.mid *= 0.85; engine.high *= 0.85; engine.level *= 0.85
            if sentConfidence > 0, let t = s.tempo {
                engine.audioTempo(bpm: t.bpm, beatTime: t.beatTime, confidence: 0)
                sentConfidence = 0
            }
        } else {
            engine.bass = s.levels.bass
            engine.mid = s.levels.mid
            engine.high = s.levels.high
            engine.level = s.levels.level
        }
        if !stalled, s.serial != lastSerial, let t = s.tempo {
            lastSerial = s.serial
            // tap timestamps are when the audio leaves the mixer; it's heard `outputLatency` later,
            // and a frame rendered now is seen `displayLatency` later
            let beat = t.beatTime + outputLatency - Self.displayLatency + Self.userOffset
            engine.audioTempo(bpm: t.bpm, beatTime: beat, confidence: t.confidence)
            sentConfidence = t.confidence
        }
        if now - lastStatusUpdate > 0.25 {
            lastStatusUpdate = now
            let status = statusText(s, now: now, stalled: stalled)
            if engine.audioStatus != status { engine.audioStatus = status }
        }
    }

    private func statusText(_ s: Shared, now: CFTimeInterval, stalled: Bool) -> String {
        if let startError { return startError }
        let running = now - startedAt
        if s.buffers == 0 && running < 1 { return "Starting…" }
        if stalled || s.silentFor > 0.5 || (s.tempo == nil && !s.heardSound) {
            if Self.permission == .denied { return Self.permissionMessage }
            if !s.heardSound && running > 4 {
                return "Silence · nothing heard yet (if music is playing: \(Self.permissionHint))"
            }
            return "Silence"
        }
        guard let t = s.tempo, t.confidence >= 0.4 else { return "Listening… finding the beat" }
        let bpm = Int(t.bpm.rounded())
        return t.locked ? "\(bpm) bpm · locked" : "\(bpm) bpm · settling"
    }

    private func logState() {
        let s = lock.withLock { shared }
        let t = s.tempo
        print(String(format: "audio: %@ | bpm %.2f conf %.2f locked %@ | bass %.2f mid %.2f high %.2f level %.2f | peak %.4f buffers %d out-latency %.1f ms | engine %.2f bpm active %@ beat %.3f",
                     engine.audioStatus, t?.bpm ?? 0, t?.confidence ?? 0, (t?.locked ?? false) ? "yes" : "no",
                     s.levels.bass, s.levels.mid, s.levels.high, s.levels.level, s.peak, s.buffers, outputLatency * 1000,
                     engine.currentBPM, engine.audioActive ? "yes" : "no", engine.beat))
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { print("  " + tap.debugDescription) }
        fflush(stdout)
    }

    // MARK: Permission ("System Audio Recording", TCC service kTCCServiceAudioCapture)

    private enum Permission { case granted, denied, unknown }

    /// Cached for 2 s (it's an IPC round trip).
    private static var permission: Permission {
        let now = CACurrentMediaTime()
        if now - permissionChecked > 2 {
            permissionChecked = now
            cachedPermission = checkPermission()
        }
        return cachedPermission
    }
    private static var permissionChecked: CFTimeInterval = -10
    private static var cachedPermission = Permission.unknown

    /// Best effort: TCC's preflight isn't public API, so it's looked up at runtime and may say `.unknown`.
    private static func checkPermission() -> Permission {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let handle = tccHandle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    private static let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static var appName: String {
        Bundle.main.bundleIdentifier == nil ? "your terminal app" : "Visual Synth"
    }

    private static var permissionHint: String {
        "allow \(appName) in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only"
    }

    private static var permissionMessage: String {
        "No permission to hear the Mac's audio: \(permissionHint), then switch sync off and on"
    }
}

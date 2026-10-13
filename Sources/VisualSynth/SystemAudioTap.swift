import AudioToolbox
import CoreAudio
import Foundation

/// Captures what the Mac is playing (all processes except our own) with a Core Audio process tap
/// (macOS 14.2+): a global stereo tap wrapped in a private aggregate device whose IO block hands us
/// the mixed output. Needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription);
/// macOS asks the first time the device starts. When the permission is denied the tap just delivers
/// silence, so callers should treat long silence as "maybe no permission".
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum TapError: Error, CustomStringConvertible {
        case failed(String, OSStatus)
        var description: String {
            switch self { case let .failed(what, status): return "\(what) failed (\(fourCC(status)))" }
        }
    }

    /// Called on `queue` for every IO cycle: mono samples, their sample rate, and the host time
    /// (CACurrentMediaTime base, seconds) of the first sample.
    typealias Handler = (_ samples: UnsafeBufferPointer<Float>, _ sampleRate: Double, _ hostTime: Double) -> Void

    private let queue: DispatchQueue
    private let handler: Handler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var mono: [Float] = []
    private(set) var sampleRate: Double = 48000
    /// How much later than its timestamp the captured audio comes out of the speakers, seconds.
    private(set) var outputLatency: Double = 0
    private(set) var outputName = ""
    /// The output device the tap is clocked from (the default output when it started).
    private(set) var outputDevice = AudioObjectID(kAudioObjectUnknown)

    init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        stop()
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "VisualSynth beat sync"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw TapError.failed("Creating the audio tap", status) }

        var format = AudioStreamBasicDescription()
        if Self.get(tapID, kAudioTapPropertyFormat, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        let output = Self.defaultOutputDevice()
        outputDevice = output ?? AudioObjectID(kAudioObjectUnknown)
        var subDevices: [[String: Any]] = []
        if let output, let uid = Self.deviceUID(output) {
            subDevices.append([kAudioSubDeviceUIDKey: uid])
            outputLatency = Self.outputLatency(of: output)
            outputName = Self.deviceName(output) ?? ""
        }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VisualSynth Tap",
            kAudioAggregateDeviceUIDKey: "local.visualsynth.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        if let first = subDevices.first?[kAudioSubDeviceUIDKey] {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = first
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError.failed("Creating the capture device", status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.receive(input, inputTime)
        }
        guard status == noErr else { stop(); throw TapError.failed("Opening the capture device", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw TapError.failed("Starting the capture", status) }
    }

    /// For diagnostics: is the capture device running, and the tap's sample format.
    var debugDescription: String {
        var running: UInt32 = 0
        Self.get(aggregateID, kAudioDevicePropertyDeviceIsRunning, &running)
        var format = AudioStreamBasicDescription()
        Self.get(tapID, kAudioTapPropertyFormat, &format)
        return "tap \(tapID) agg \(aggregateID) running \(running) \(format.mSampleRate) Hz \(format.mChannelsPerFrame) ch out \(outputName)"
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        // Tap buffers are Float32; either interleaved (1 buffer, n channels) or one buffer per channel.
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (4 * max(1, channels))
        guard frames > 0 else { return }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        let f = data.assumingMemoryBound(to: Float.self)
        if list.count == 1 {
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += f[i * channels + c] }
                mono[i] = s / Float(max(1, channels))
            }
        } else {
            for i in 0..<frames { mono[i] = f[i] }
            for b in 1..<list.count {
                guard let d = list[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += d[i] }
            }
            let scale = 1 / Float(list.count)
            for i in 0..<frames { mono[i] *= scale }
        }
        var host = Self.hostSeconds(time.pointee)
        if host == 0 { host = CACurrentMediaTimeCompat() }
        mono.withUnsafeBufferPointer { handler(UnsafeBufferPointer(rebasing: $0[0..<frames]), sampleRate, host) }
    }

    // MARK: Core Audio helpers

    private static func hostSeconds(_ t: AudioTimeStamp) -> Double {
        guard t.mFlags.contains(.hostTimeValid), t.mHostTime != 0 else { return 0 }
        return Double(AudioConvertHostTimeToNanos(t.mHostTime)) / 1e9
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    @discardableResult
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device)
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard get(object, selector, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    /// Device + stream latency of the output, in seconds. Tap timestamps match the output IO timestamps
    /// (measured: within 1.2 ms of an AVAudioEngine source's render host time), which already include
    /// the safety offset and buffer, so only what happens after the IO engine is added: device
    /// latency (Bluetooth codecs show up here) and stream latency (e.g. the speaker DSP, ~20 ms on a MacBook).
    static func outputLatency(of device: AudioObjectID) -> Double {
        var rate: Float64 = 0
        get(device, kAudioDevicePropertyNominalSampleRate, &rate)
        guard rate > 0 else { return 0 }
        var latency: UInt32 = 0
        get(device, kAudioDevicePropertyLatency, &latency, scope: kAudioObjectPropertyScopeOutput)
        var streamLatency: UInt32 = 0
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let s = streams.first {
                get(s, kAudioStreamPropertyLatency, &streamLatency)
            }
        }
        return min(0.5, Double(latency + streamLatency) / rate)
    }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xff))) }
    if chars.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }) { return "'" + String(chars) + "'" }
    return String(status)
}

private func CACurrentMediaTimeCompat() -> Double {
    Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) / 1e9
}

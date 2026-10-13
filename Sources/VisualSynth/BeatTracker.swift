import Accelerate
import Foundation

/// Real-time beat tracker and band meter for a mono PCM stream. Pure DSP, no audio I/O:
/// feed it buffers with the host time of their first sample, read `levels` / `tempo`.
/// Not thread-safe: call everything from one (background) queue.
///
/// Onsets: log-compressed spectral flux (Hann 1024 / hop 256 at 48 kHz → ~190 frames/s).
/// Tempo: autocorrelation of the last 8 s of onset envelope, scored by a 4-harmonic comb with a
/// mild prior around 120 bpm, folded into 68…185 bpm with an explicit double/half-time check,
/// smoothed with hysteresis. Phase: a decaying beat comb aligned to the last 4 s of onsets.
final class BeatTracker {
    struct Levels { var bass: Float = 0, mid: Float = 0, high: Float = 0, level: Float = 0 }

    struct Tempo {
        var bpm: Double
        /// Host time (same clock as the input timestamps) of a recent beat.
        var beatTime: Double
        /// 0…1: how sure we are (pulse clarity × stability; 0 in silence).
        var confidence: Double
        /// Tempo has been stable for a while.
        var locked: Bool
    }

    let sampleRate: Double
    let fps: Double                     // onset envelope frame rate
    static let minBPM = 68.0, maxBPM = 185.0

    private(set) var levels = Levels()
    private(set) var tempo: Tempo?
    /// Bumped whenever `tempo` is re-estimated.
    private(set) var tempoSerial = 0
    /// RMS of the input over the last ~second is below -80 dBFS.
    private(set) var silent = true
    /// Seconds of continuous silence.
    private(set) var silentFor: Double = 0

    // Framing
    private let window: Int, hop: Int
    private var pending: [Float] = []
    private var pendingTime: Double = 0        // host time of pending[0]
    private let hann: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let log2n: vDSP_Length
    private var real: [Float], imag: [Float], frame: [Float]
    private var mag: [Float], prevComp: [Float], comp: [Float]
    /// Log-spaced flux bands (bin ranges) and their weights: every octave counts about the same,
    /// lows a bit more (kicks and bass carry the beat; hats on the off-beats shouldn't win the phase).
    private let fluxBands: [(lo: Int, hi: Int, weight: Float)]
    private let bandBins: [(Int, Int)]          // bass, mid, high
    private let magScale: Float

    // Onset envelope history (ring)
    private let capacity: Int
    private var env: [Float]
    private var envCount = 0                    // total frames ever written
    private var lastFrameTime: Double = 0       // host time of the newest frame (window centre)

    // Loudness tracking
    private var slowRMS: Float = 0
    private var fastRMS: Float = 0
    private var bandMean: [Float] = [-60, -60, -60, -60]   // dB, slow mean
    private var bandPeak: [Float] = [-40, -40, -40, -40]   // dB, decaying peak
    private var bandOut: [Float] = [0, 0, 0, 0]

    // Tempo state
    private var framesSinceEstimate = 0
    private let estimateEvery: Int
    private var bpm: Double = 0                 // smoothed tempo (0 = none yet)
    private var candidate: Double = 0           // a different tempo waiting to prove itself
    private var candidateHits = 0
    private var stableSince: Double = 0
    private var beatTime: Double = 0            // smoothed phase reference (frame-time clock)
    private var clarity: Double = 0             // smoothed pulse clarity 0…1
    private var acf: [Float] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var w = 1024
        while Double(w) < sampleRate * 0.0213 * 0.75 { w *= 2 }   // ~21 ms
        window = w
        hop = w / 4
        fps = sampleRate / Double(hop)
        estimateEvery = max(1, Int(fps / 4))                      // every 0.25 s
        log2n = vDSP_Length(log2(Double(w)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: w, isHalfWindow: false)
        real = [Float](repeating: 0, count: w / 2)
        imag = real
        frame = [Float](repeating: 0, count: w)
        mag = real; prevComp = real; comp = real
        magScale = 2 / hann.reduce(0, +) / 2   // vDSP's packed real FFT is ×2
        let binHz = sampleRate / Double(w)
        func bin(_ hz: Double) -> Int { min(w / 2 - 1, max(1, Int((hz / binHz).rounded()))) }
        let edges: [Double] = [30, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 12000]
        let weights: [Float] = [2, 2, 1.5, 1, 1, 1, 0.8, 0.8, 0.8]
        fluxBands = (0..<weights.count).map { i in
            let lo = bin(edges[i]), hi = max(lo, bin(edges[i + 1]) - 1)
            return (lo, hi, weights[i])
        }
        bandBins = [(bin(20), bin(150)), (bin(150) + 1, bin(2000)), (bin(2000) + 1, bin(12000))]
        capacity = Int(fps * 10)
        env = [Float](repeating: 0, count: capacity)
    }

    // MARK: Input

    func process(_ samples: UnsafeBufferPointer<Float>, hostTime: Double) {
        let expected = pendingTime + Double(pending.count) / sampleRate
        if pending.isEmpty || abs(hostTime - expected) > 0.05 {
            // first buffer or a discontinuity: restart framing at this buffer's clock
            pending.removeAll(keepingCapacity: true)
            pendingTime = hostTime
        }
        pending.append(contentsOf: samples)
        var consumed = 0
        while pending.count - consumed >= window {
            pending.withUnsafeBufferPointer { analyze(UnsafeBufferPointer(rebasing: $0[consumed..<consumed + window])) }
            lastFrameTime = pendingTime + (Double(consumed) + Double(window) / 2) / sampleRate
            consumed += hop
            pushFrameDone()
        }
        if consumed > 0 {
            pending.removeFirst(consumed)
            pendingTime += Double(consumed) / sampleRate
        }
    }

    private func analyze(_ x: UnsafeBufferPointer<Float>) {
        // loudness
        let rms = vDSP.rootMeanSquare(x)
        fastRMS = max(rms, fastRMS * 0.97)
        let dt = 1 / Float(fps)
        slowRMS += (rms - slowRMS) * min(1, dt / 3)
        silentFor = fastRMS < 1e-4 ? silentFor + Double(dt) : 0
        silent = silentFor > 0.5

        // spectrum
        vDSP.multiply(x, hann, result: &frame)
        let half = window / 2
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                im[0] = 0   // packed Nyquist; drop it
                vDSP.absolute(split, result: &mag)
            }
        }
        vDSP.multiply(magScale, mag, result: &mag)

        // band levels (power → dB → auto-ranged 0…1)
        var powers: [Float] = bandBins.map { lo, hi in
            var s: Float = 0
            for k in lo...hi { s += mag[k] * mag[k] }
            return s
        }
        powers.append(rms * rms * 2)
        for i in 0..<4 {
            let db = 10 * log10(powers[i] + 1e-12)
            if db > -85 { bandMean[i] += (db - bandMean[i]) * dt / 4 }
            bandPeak[i] = max(db, bandPeak[i] - dt * 1.5, bandMean[i] + 6)
            let span = max(bandPeak[i] - bandMean[i], 6)
            var v = 0.45 + 0.5 * (db - bandMean[i]) / span
            if db < -85 || silent { v = 0 }
            v = min(1, max(0, v))
            // fast attack, ~150 ms release
            bandOut[i] = v > bandOut[i] ? bandOut[i] + (v - bandOut[i]) * 0.5 : bandOut[i] + (v - bandOut[i]) * dt / 0.15
        }
        levels = Levels(bass: bandOut[0], mid: bandOut[1], high: bandOut[2], level: bandOut[3])

        // onset strength: log-compressed spectral flux, level-normalized
        let gain = 0.1 / max(slowRMS, 1e-3) * 100
        vDSP.multiply(gain, mag, result: &comp)
        var flux: Float = 0
        for band in fluxBands {
            var sum: Float = 0
            for k in band.lo...band.hi {
                let c = log1pf(comp[k])
                let d = c - prevComp[k]
                if d > 0 { sum += d }
                prevComp[k] = c
            }
            flux += band.weight * sum / Float(band.hi - band.lo + 1)
        }
        if fastRMS < 1e-4 { flux = 0 }
        env[envCount % capacity] = flux
        envCount += 1
    }

    private func pushFrameDone() {
        framesSinceEstimate += 1
        if framesSinceEstimate >= estimateEvery {
            framesSinceEstimate = 0
            estimate()
        }
    }

    // MARK: Tempo & phase

    /// The last `n` envelope frames, oldest first.
    private func recent(_ n: Int) -> [Float] {
        let n = min(n, envCount, capacity)
        return (0..<n).map { env[(envCount - n + $0) % capacity] }
    }

    private func estimate() {
        if silent {
            clarity = 0
            if tempo != nil { tempo?.confidence = 0; tempo?.locked = false; tempoSerial += 1 }
            stableSince = lastFrameTime
            return
        }
        let have = min(envCount, capacity)
        guard Double(have) > fps * 2.5 else { return }
        var x = recent(Int(fps * 8))
        let n = x.count
        // detrend: subtract a centred ~0.25 s moving average, half-wave rectify, light smoothing
        x = Self.onsetDetrend(x, width: Int(fps * 0.25))
        let mean = vDSP.mean(x)
        // recency taper (older half fades to 0.4) so tempo changes show up sooner
        var xc = vDSP.add(-mean, x)
        for i in 0..<n { xc[i] *= Float(0.4 + 0.6 * min(1, Double(i) / Double(n / 2))) }

        // autocorrelation, same number of terms at every lag
        let tauMax = fps * 60 / Self.minBPM
        let lagMax = min(n - Int(fps * 1.5), max(Int(4 * tauMax) + 3, n / 2))
        let terms = n - lagMax
        acf = [Float](repeating: 0, count: lagMax)
        xc.withUnsafeBufferPointer { a in
            acf.withUnsafeMutableBufferPointer { r in
                vDSP_conv(a.baseAddress!, 1, a.baseAddress!, 1, r.baseAddress!, 1, vDSP_Length(lagMax), vDSP_Length(terms))
            }
        }
        let r0 = max(acf[0], 1e-9)
        func r(_ lag: Double) -> Double {
            guard lag >= 0, lag < Double(lagMax - 1) else { return 0 }
            let i = Int(lag), f = Float(lag - Double(i))
            // max of interpolated value and neighbours: tolerant to tiny timing jitter
            let v = acf[i] * (1 - f) + acf[i + 1] * f
            return Double(v) / Double(r0)
        }
        func comb(_ b: Double) -> Double {
            let tau = fps * 60 / b
            var s = 0.0, k = 1.0
            while k <= 4, k * tau < Double(lagMax - 1) { s += r(k * tau); k += 1 }
            return s / max(1, k - 1)
        }
        func prior(_ b: Double) -> Double { let o = log2(b / 120) / 0.9; return exp(-0.5 * o * o) }

        var bestB = 0.0, bestS = -1.0
        var scores: [Double] = []
        var b = Self.minBPM
        while b <= Self.maxBPM {
            let s = comb(b) * prior(b)
            scores.append(s)
            if s > bestS { bestS = s; bestB = b }
            b += 0.25
        }
        // refine around the grid peak
        for step in [0.05, 0.01] {
            let centre = bestB
            var bb = centre - 0.25
            while bb <= centre + 0.25 { let s = comb(bb) * prior(bb); if s > bestS { bestS = s; bestB = bb }; bb += step }
        }
        // double / half time: odd multiples of the fast period are what the slow tempo can't explain
        func oddEvidence(_ fast: Double) -> Double {
            let tau = fps * 60 / fast
            let odd = (r(tau) + r(3 * tau)) / 2, even = (r(2 * tau) + r(4 * tau)) / 2
            return even > 0.02 ? odd / even : 0
        }
        // sticky: once a metrical level is chosen it takes clearer evidence to leave it
        var est = bestB
        func near(_ a: Double) -> Bool { bpm > 0 && abs(a - bpm) / bpm < 0.04 }
        let up = near(est * 2) ? 0.45 : near(est) ? 0.85 : 0.65
        let down = near(est / 2) ? 0.45 : near(est) ? 0.2 : 0.3
        if est * 2 <= Self.maxBPM, oddEvidence(est * 2) > up { est *= 2 }
        else if est / 2 >= Self.minBPM, oddEvidence(est) < down { est /= 2 }
        if est != bestB { est = refine(est, comb) }
        // fine-tune: least-squares period through the parabolic-interpolated ACF peaks at k·τ
        do {
            let tau = fps * 60 / est
            var num = 0.0, den = 0.0, k = 1.0
            while k <= 12, k * tau + 3 < Double(lagMax - 1) {
                let c = Int((k * tau).rounded())
                var i = c
                for j in (c - 2)...(c + 2) where j > 0 && acf[j] > acf[i] { i = j }
                let a = Double(acf[i - 1]), b = Double(acf[i]), d = Double(acf[i + 1])
                let denom = a - 2 * b + d
                let p = Double(i) + (denom < 0 ? 0.5 * (a - d) / denom : 0)
                let w = max(0, b / Double(r0))
                num += w * k * p; den += w * k * k
                k += 1
            }
            if den > 0 {
                let refined = fps * 60 / (num / den)
                if abs(refined - est) / est < 0.015 { est = refined }
            }
        }

        // pulse clarity: comb peak vs typical comb value
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let peak = comb(est)
        let rawClarity = max(0, min(1, (peak - max(0, median)) * 2.2))
        clarity += (rawClarity - clarity) * 0.3

        updateTempo(est)
        guard bpm > 0 else { return }
        updatePhase(x)

        let stable = min(1, (lastFrameTime - stableSince) / 3)
        let confidence = clarity * (0.5 + 0.5 * stable)
        tempo = Tempo(bpm: bpm, beatTime: beatTime, confidence: confidence,
                      locked: stable >= 1 && clarity > 0.35)
        tempoSerial += 1
    }

    private func refine(_ b: Double, _ comb: (Double) -> Double) -> Double {
        var best = b, bestS = comb(b), x = b - 1
        while x <= b + 1 { let s = comb(x); if s > bestS { bestS = s; best = x }; x += 0.02 }
        return best
    }

    /// Tempo smoothing with hysteresis: small changes glide, big changes need repeated agreement.
    private func updateTempo(_ est: Double) {
        if bpm == 0 {
            bpm = est
            stableSince = lastFrameTime
            return
        }
        let rel = abs(est - bpm) / bpm
        if rel < 0.04 {
            bpm += (est - bpm) * 0.25
            candidateHits = 0
            return
        }
        // octave-related estimates need more evidence than unrelated ones
        let ratio = est / bpm
        let octave = abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.04 || abs(ratio - 1.5) < 0.06 || abs(ratio - 2.0 / 3) < 0.03
        if candidate > 0, abs(est - candidate) / candidate < 0.04 { candidateHits += 1; candidate = (candidate + est) / 2 }
        else { candidate = est; candidateHits = 1 }
        if candidateHits >= (octave ? 12 : 4) {   // 3 s / 1 s of agreement
            bpm = candidate
            candidateHits = 0
            stableSince = lastFrameTime
            beatTime = 0
        }
    }

    /// Align a decaying beat comb to the last 4 s of onsets; smooth the result.
    private func updatePhase(_ e: [Float]) {
        let tau = fps * 60 / bpm
        let n = e.count
        let span = min(Double(n - 2), fps * 4)
        func at(_ pos: Double) -> Double {   // pos in frames from the newest (0 = newest)
            let p = Double(n - 1) - pos
            guard p >= 0 else { return 0 }
            let i = Int(p), f = Float(p - Double(i))
            return Double(i + 1 < n ? e[i] * (1 - f) + e[i + 1] * f : e[i])
        }
        var bestPhi = 0.0, best = -1.0
        var phi = 0.0
        while phi < tau {
            var s = 0.0, w = 1.0, pos = phi
            while pos < span { s += w * at(pos); w *= 0.85; pos += tau }
            if s > best { best = s; bestPhi = phi }
            phi += 0.25
        }
        let measured = lastFrameTime - bestPhi / fps + Self.onsetBias
        let period = 60 / bpm
        if beatTime == 0 {
            beatTime = measured
            return
        }
        // move the old reference forward to near the measurement, then blend
        let k = ((measured - beatTime) / period).rounded()
        let predicted = beatTime + k * period
        var err = measured - predicted
        if abs(err) > period / 2 { err -= (err / period).rounded() * period }
        beatTime = predicted + err * (abs(err) < period * 0.15 ? 0.35 : 0.15)
    }

    /// Spectral flux peaks a little after the true onset (the window centre trails the attack).
    /// Calibrated on synthetic kicks and clicks: see the test harness.
    static var onsetBias = 0.004

    private static func onsetDetrend(_ x: [Float], width: Int) -> [Float] {
        let n = x.count
        guard n > 2 else { return x }
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        let h = max(1, width / 2)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - h), hi = min(n, i + h + 1)
            let m = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            y[i] = max(0, x[i] - m)
        }
        // [1 2 1]/4 smoothing
        var z = y
        for i in 1..<(n - 1) { z[i] = 0.25 * y[i - 1] + 0.5 * y[i] + 0.25 * y[i + 1] }
        return z
    }
}

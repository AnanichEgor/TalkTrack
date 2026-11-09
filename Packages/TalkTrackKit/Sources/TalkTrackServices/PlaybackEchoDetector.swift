import Accelerate
import Dispatch
import Foundation
import Synchronization
import TalkTrackAudio
import TalkTrackDomain

/// One measurement of whether the system audio reappears in the microphone.
/// Times are microseconds of the recording's active timeline.
public struct EchoMeasurement: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    /// Peak normalized cross-correlation over the lag range (0…1).
    public var peak: Float
    /// Microphone delay behind the system audio at the peak.
    public var lagMilliseconds: Double
    /// The system audio (or the microphone) was too quiet to measure.
    public var silent: Bool
}

/// Waveform cross-correlation of 16 kHz system and microphone audio (design D1).
/// Pre-emphasis whitens speech so the echo shows as a sharp peak; FFT finds the
/// lag, then the exact dot product gives the peak.
final class PlaybackEchoCorrelator {
    static let rate = 16_000
    /// 3 s of system audio per measurement.
    static let window = 48_000
    /// Microphone delay range searched: the tap hears audio before the speaker
    /// plays it, so echo lags 5–300 ms behind; a little negative lag is allowed.
    static let minimumLag = -800   // −50 ms
    static let maximumLag = 6_400  // +400 ms
    static let lagCount = maximumLag - minimumLag + 1
    /// Microphone samples a measurement needs: the window plus the lag range.
    static let microphoneLength = window + lagCount - 1
    /// Below these levels (raw 16 kHz RMS) a window is `silent` (prototype, 2026-11-05).
    static let systemFloorDB: Float = -45
    static let microphoneFloorDB: Float = -75

    private static let log2n: vDSP_Length = 16
    private static let size = 1 << 16
    private let setup: FFTSetup

    init() { setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))! }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// `system` has `window` samples; `microphone` has `microphoneLength`, starting
    /// at the window's start plus `minimumLag`.
    func measure(system: [Float], microphone: [Float]) -> (peak: Float, lagSamples: Int, silent: Bool) {
        precondition(system.count == Self.window && microphone.count == Self.microphoneLength)
        if Self.rmsDB(system) < Self.systemFloorDB || Self.rmsDB(microphone) < Self.microphoneFloorDB {
            return (0, 0, true)
        }
        let s = Self.preEmphasized(system), m = Self.preEmphasized(microphone)
        let raw = correlate(s, m)
        var es: Float = 0
        vDSP_svesq(s, 1, &es, vDSP_Length(s.count))
        // Sliding microphone energy for each lag, in Double to avoid cancellation.
        var cumulative = [Double](repeating: 0, count: m.count + 1)
        for i in 0..<m.count { cumulative[i + 1] = cumulative[i] + Double(m[i] * m[i]) }
        var bestK = 0, bestScore = -1.0
        for k in 0..<Self.lagCount {
            let em = cumulative[k + Self.window] - cumulative[k]
            guard em > 0 else { continue }
            let score = Double(abs(raw[k])) / em.squareRoot()
            if score > bestScore { bestScore = score; bestK = k }
        }
        guard bestScore > 0, es > 0 else { return (0, 0, false) }
        var dot: Float = 0
        m.withUnsafeBufferPointer { vDSP_dotpr(s, 1, $0.baseAddress! + bestK, 1, &dot, vDSP_Length(Self.window)) }
        let em = cumulative[bestK + Self.window] - cumulative[bestK]
        let peak = Float(Double(abs(dot)) / (Double(es) * em).squareRoot())
        return (min(1, peak), bestK + Self.minimumLag, false)
    }

    /// c[k] = Σ s[n]·m[n+k] for k in 0..<lagCount, up to a constant scale.
    private func correlate(_ s: [Float], _ m: [Float]) -> [Float] {
        let half = Self.size / 2
        func spectrum(_ x: [Float]) -> ([Float], [Float]) {
            var padded = x + [Float](repeating: 0, count: Self.size - x.count)
            var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeMutableBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }
        let (a, b) = spectrum(s), (c, d) = spectrum(m)
        // conj(S)·M; bin 0 packs DC (real) and Nyquist (imaginary), both real.
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        re[0] = a[0] * c[0]; im[0] = b[0] * d[0]
        for i in 1..<half {
            re[i] = a[i] * c[i] + b[i] * d[i]
            im[i] = a[i] * d[i] - b[i] * c[i]
        }
        var out = [Float](repeating: 0, count: Self.size)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes {
                    vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        return Array(out.prefix(Self.lagCount))
    }

    static func preEmphasized(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return [] }
        var y = x
        for i in stride(from: x.count - 1, to: 0, by: -1) { y[i] = x[i] - 0.95 * x[i - 1] }
        y[0] = 0
        return y
    }

    static func rmsDB(_ x: [Float]) -> Float {
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return 20 * log10(max(r, 1e-9))
    }
}

/// Streaming 48 kHz → 16 kHz decimation with a windowed-sinc low-pass. Output
/// sample j is centred on input frame 3j, so both tracks stay on one grid.
struct EchoDecimator {
    static let taps: [Float] = {
        let count = 31, centre = 15, cutoff: Float = 7_000 / 48_000
        var h = (0..<count).map { i -> Float in
            let x = Float(i - centre)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let blackman = 0.42 - 0.5 * cos(2 * .pi * Float(i) / Float(count - 1)) + 0.08 * cos(4 * .pi * Float(i) / Float(count - 1))
            return sinc * blackman
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h
    }()
    static let half = 15

    private var input: [Float] = []
    private var inputBase: UInt64 = 0
    /// Next 16 kHz index to produce.
    private(set) var next: Int64?

    /// Appends contiguous 48 kHz audio and returns new 16 kHz samples with the
    /// index of the first one. A discontinuity must be signalled with `reset()`.
    mutating func append(_ samples: [Float], start: UInt64) -> (start: Int64, samples: [Float])? {
        if next == nil || start != inputBase + UInt64(input.count) {
            input = []; inputBase = start
            next = (Int64(start) + Int64(Self.half) + 2) / 3
        }
        input.append(contentsOf: samples)
        let first = next! * 3 - Int64(Self.half) - Int64(inputBase)
        guard first >= 0 else { return nil }
        let available = input.count - Int(first) - Self.taps.count
        guard available >= 0 else { return nil }
        let count = available / 3 + 1
        var out = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer {
            vDSP_desamp($0.baseAddress! + Int(first), 3, Self.taps, &out, vDSP_Length(count), vDSP_Length(Self.taps.count))
        }
        let produced = next!
        next = produced + Int64(count)
        // Keep what the next output's filter still needs.
        let keep = Int(next! * 3 - Int64(Self.half) - Int64(inputBase))
        let drop = min(max(keep, 0), input.count)
        if drop > 0 { input.removeFirst(drop); inputBase += UInt64(drop) }
        return (produced, out)
    }
}

/// Turns measurements into stable loudspeaker / headset stretches (design D2).
/// Loudspeakers need a high share of strong measurements among the last
/// `history` non-silent ones; a headset needs a low median peak. The previous
/// state holds in between (hysteresis).
struct PlaybackEchoClassifier {
    static let history = 20
    /// A peak above this is echo. Measured medians: loudspeakers 0.25–0.29,
    /// headset 0.014, shifted-microphone control 0.02–0.03 (2026-11-05).
    static let strongPeak: Float = 0.1
    /// 8 measurements ≈ 13.5 s of others speaking. Real loudspeaker calls had
    /// 99–100% strong windows; the headset call opened with 3 strong windows in
    /// its first 6, which a 6-window / 50% rule misread as loudspeakers (2026-11-05).
    static let loudspeakerMinimum = 8
    static let loudspeakerShare = 0.7
    /// Echo comes from one acoustic path: strong peaks cluster on one delay
    /// (65–72% within ±10 ms on real loudspeaker calls).
    static let clusterShare = 0.35
    static let clusterWidth = 15.0
    static let headsetMinimum = 12
    /// A headset needs the median peak of the recent measurements below this.
    /// Medians: wired/USB headset call 0.013, Bluetooth headset after its echo
    /// canceller settled 0.028 (with residual peaks 0.10–0.16 in 25% of windows,
    /// which a share rule refused), loudspeakers 0.19–0.29 (2026-11-05).
    static let headsetMedianPeak: Float = 0.06
    /// After a device change or gap, measurements starting within this time are
    /// ignored: a Bluetooth headset's echo canceller converges first (peaks 0.56,
    /// 0.50 in the first 3 s after the switch, 2026-11-05).
    static let settleMicroseconds: Int64 = 6_000_000

    private(set) var state = PlaybackEchoState.unknown
    private var recent: [EchoMeasurement] = []
    private var closed: [PlaybackEchoStretch] = []
    private var open: (state: PlaybackEchoState, start: Int64, peaks: [Float], lags: [Double])?
    private var lastEnd: Int64 = 0
    /// True after `interrupt()` until the first measurement sets `settleUntil`.
    private var settling = false
    private var settleUntil: Int64 = .min

    /// Returns true when the state changed.
    mutating func add(_ m: EchoMeasurement) -> Bool {
        lastEnd = max(lastEnd, m.end)
        if settling { settling = false; settleUntil = m.start + Self.settleMicroseconds }
        guard !m.silent, m.start >= settleUntil else { return false }
        recent.append(m)
        if recent.count > Self.history { recent.removeFirst(recent.count - Self.history) }
        if open != nil {
            open!.peaks.append(m.peak)
            if m.peak > Self.strongPeak { open!.lags.append(m.lagMilliseconds) }
        }
        let strong = recent.filter { $0.peak > Self.strongPeak }
        let count = Double(recent.count)
        var next = state
        if recent.count >= Self.loudspeakerMinimum, Double(strong.count) >= Self.loudspeakerShare * count,
           Double(Self.clustered(strong)) >= Self.clusterShare * count {
            next = .loudspeaker
        } else if recent.count >= Self.headsetMinimum, Self.median(recent.map(\.peak)) < Self.headsetMedianPeak,
                  m.peak <= Self.strongPeak {
            // A headset stretch starts after the last strong window, so it waits
            // for a weak one.
            next = .headset
        }
        guard next != state else { return false }
        var start: Int64
        if next == .loudspeaker { start = strong.first!.start }
        else {
            let lastStrong = recent.lastIndex { $0.peak > Self.strongPeak }
            start = recent[lastStrong.map { $0 + 1 } ?? 0].start
        }
        if let current = open { start = max(start, current.start) }
        closeOpen(at: start)
        let evidence = recent.filter { $0.start >= start }
        open = (next, start, evidence.map(\.peak),
                evidence.filter { $0.peak > Self.strongPeak }.map(\.lagMilliseconds))
        state = next
        return true
    }

    /// A device change or gap: what follows may be a different output.
    mutating func interrupt() {
        closeOpen(at: lastEnd)
        open = nil; recent = []; state = .unknown
        settling = true
    }

    /// Closed stretches plus the open one up to the latest measurement.
    func stretches() -> [PlaybackEchoStretch] {
        guard let open, lastEnd > open.start, let stretch = Self.stretch(open, end: lastEnd) else { return closed }
        return closed + [stretch]
    }

    /// Median lag of the current loudspeaker stretch, for diagnostics.
    var currentPeak: Float { open.map { Self.median($0.peaks) } ?? 0 }
    var currentLag: Double? { open.flatMap { $0.lags.isEmpty ? nil : Self.median($0.lags) } }

    private mutating func closeOpen(at end: Int64) {
        if let current = open, let stretch = Self.stretch(current, end: end) { closed.append(stretch) }
        open = nil
    }

    private static func stretch(_ open: (state: PlaybackEchoState, start: Int64, peaks: [Float], lags: [Double]),
                                end: Int64) -> PlaybackEchoStretch? {
        guard end > open.start, let interval = try? MediaInterval(start: MediaTime(microseconds: open.start),
                                                                    end: MediaTime(microseconds: end)) else { return nil }
        return PlaybackEchoStretch(active: interval, state: open.state, peak: median(open.peaks),
                                   lagMilliseconds: open.state == .loudspeaker && !open.lags.isEmpty ? median(open.lags) : nil)
    }

    static func clustered(_ strong: [EchoMeasurement]) -> Int {
        guard !strong.isEmpty else { return 0 }
        let centre = median(strong.map(\.lagMilliseconds))
        return strong.filter { abs($0.lagMilliseconds - centre) <= clusterWidth }.count
    }

    static func median<T: Comparable & Numeric>(_ x: [T]) -> T { x.isEmpty ? 0 : x.sorted()[x.count / 2] }
}

/// Live loudspeaker detection beside the capture pipeline (design D3). The
/// pipeline appends aligned 48 kHz audio and never waits: appending decimates
/// under a lock, and correlation runs on a utility queue. When analysis falls
/// behind, older windows are skipped (they stay unknown) instead of queuing.
public final class PlaybackEchoMonitor: Sendable {
    public struct Status: Equatable, Sendable {
        public var state = PlaybackEchoState.unknown
        public var measured = 0
        public var skipped = 0
    }

    private struct Track {
        var decimator = EchoDecimator()
        var samples: [Float] = []
        /// 16 kHz index of `samples[0]`.
        var base: Int64 = 0
    }

    private struct State {
        var tracks: [AudioTrack: Track] = [.system: Track(), .microphone: Track()]
        /// 16 kHz index where the next measurement's system window starts.
        var nextWindow: Int64?
        var generation = 0
        var scheduled = false
        var classifier = PlaybackEchoClassifier()
        var status = Status()
    }

    static let hop: Int64 = 24_000  // 1.5 s at 16 kHz
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "local.talktrack.playback-echo", qos: .utility)
    private let correlator = Mutex(PlaybackEchoCorrelator())
    private let recordingID: UUID?
    private let maximumBacklog: Int
    private let onChange: @Sendable (PlaybackEchoState) -> Void
    private let onMeasurement: (@Sendable (EchoMeasurement) -> Void)?

    /// `maximumBacklog` windows may wait for analysis (4 ≈ 6 s during capture);
    /// beyond that the oldest are skipped. Offline replay passes `.max` and
    /// observes every measurement.
    public init(recordingID: UUID? = nil, maximumBacklog: Int = 4,
                onMeasurement: (@Sendable (EchoMeasurement) -> Void)? = nil,
                onChange: @escaping @Sendable (PlaybackEchoState) -> Void = { _ in }) {
        self.recordingID = recordingID; self.maximumBacklog = max(1, maximumBacklog)
        self.onMeasurement = onMeasurement; self.onChange = onChange
    }

    public var status: Status { state.withLock { $0.status } }

    /// Aligned 48 kHz audio at an active frame. Contiguous per track until a
    /// `pause()` or `interrupt()`.
    public func append(_ track: AudioTrack, samples: [Float], start: UInt64) {
        let schedule = state.withLock { s -> Bool in
            guard let out = s.tracks[track]!.decimator.append(samples, start: start) else { return false }
            if s.tracks[track]!.samples.isEmpty || s.tracks[track]!.base + Int64(s.tracks[track]!.samples.count) != out.start {
                s.tracks[track]!.samples = []; s.tracks[track]!.base = out.start
                s.nextWindow = nil
            }
            s.tracks[track]!.samples.append(contentsOf: out.samples)
            guard Self.ready(&s, backlog: Int.max) != nil, !s.scheduled else { return false }
            s.scheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    /// Pause: both rings restart after Resume; the classification holds.
    public func pause() { state.withLock { Self.clear(&$0) } }

    /// A gap or device change: rings restart and the classification becomes unknown.
    public func interrupt() {
        let changed = state.withLock { s -> Bool in
            Self.clear(&s)
            let was = s.classifier.state
            s.classifier.interrupt()
            s.status.state = .unknown
            return was != .unknown
        }
        if changed { report(.unknown, at: nil, peak: 0, lag: nil) }
    }

    public func stretches() -> [PlaybackEchoStretch] { state.withLock { $0.classifier.stretches() } }

    /// Waits until every window ready so far has been analyzed.
    public func waitUntilIdle() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
        // A drain scheduled by the last append runs before this barrier.
    }

    private static func clear(_ s: inout State) {
        for key in s.tracks.keys { s.tracks[key] = Track() }
        s.nextWindow = nil; s.generation += 1
    }

    /// The start of the next window to analyze: the oldest ready one, or the
    /// newest that leaves at most `backlog` windows behind it.
    private static func ready(_ s: inout State, backlog: Int) -> Int64? {
        let system = s.tracks[.system]!, microphone = s.tracks[.microphone]!
        guard !system.samples.isEmpty, !microphone.samples.isEmpty else { return nil }
        if s.nextWindow == nil { s.nextWindow = max(system.base, microphone.base - Int64(PlaybackEchoCorrelator.minimumLag)) }
        let w = s.nextWindow!
        let systemEnd = system.base + Int64(system.samples.count)
        let microphoneEnd = microphone.base + Int64(microphone.samples.count)
        let limit = min(systemEnd - Int64(PlaybackEchoCorrelator.window),
                        microphoneEnd - Int64(PlaybackEchoCorrelator.window) - Int64(PlaybackEchoCorrelator.maximumLag))
        guard limit >= w else { return nil }
        let behind = (limit - w) / hop
        return behind < Int64(backlog) ? w : w + (behind - Int64(backlog) + 1) * hop
    }

    private func drain() {
        while true {
            let job = state.withLock { s -> (Int64, [Float], [Float], Int)? in
                guard let latest = Self.ready(&s, backlog: self.maximumBacklog) else { s.scheduled = false; return nil }
                let skipped = Int((latest - s.nextWindow!) / Self.hop)
                s.status.skipped += skipped
                let system = s.tracks[.system]!, microphone = s.tracks[.microphone]!
                let so = Int(latest - system.base)
                let mo = Int(latest + Int64(PlaybackEchoCorrelator.minimumLag) - microphone.base)
                let sys = Array(system.samples[so..<(so + PlaybackEchoCorrelator.window)])
                let mic = Array(microphone.samples[mo..<(mo + PlaybackEchoCorrelator.microphoneLength)])
                s.nextWindow = latest + Self.hop
                // Drop audio no later window needs.
                let keepFrom = s.nextWindow! + Int64(PlaybackEchoCorrelator.minimumLag)
                for key in AudioTrack.allCases {
                    let drop = Int(min(max(0, keepFrom - s.tracks[key]!.base), Int64(s.tracks[key]!.samples.count)))
                    if drop > 0 { s.tracks[key]!.samples.removeFirst(drop); s.tracks[key]!.base += Int64(drop) }
                }
                return (latest, sys, mic, s.generation)
            }
            guard let (start, sys, mic, generation) = job else { return }
            let result = correlator.withLock { $0.measure(system: sys, microphone: mic) }
            let m = EchoMeasurement(start: start * 1_000_000 / Int64(PlaybackEchoCorrelator.rate),
                                    end: (start + Int64(PlaybackEchoCorrelator.window)) * 1_000_000 / Int64(PlaybackEchoCorrelator.rate),
                                    peak: result.peak,
                                    lagMilliseconds: Double(result.lagSamples) * 1000 / Double(PlaybackEchoCorrelator.rate),
                                    silent: result.silent)
            onMeasurement?(m)
            let change = state.withLock { s -> (PlaybackEchoState, Float, Double?)? in
                guard s.generation == generation else { return nil }
                s.status.measured += 1
                guard s.classifier.add(m) else { return nil }
                s.status.state = s.classifier.state
                return (s.classifier.state, s.classifier.currentPeak, s.classifier.currentLag)
            }
            if let (new, peak, lag) = change { report(new, at: m.end, peak: peak, lag: lag) }
        }
    }

    /// Logs only the state, active time and measurements (no content).
    private func report(_ new: PlaybackEchoState, at time: Int64?, peak: Float, lag: Double?) {
        let lagText = lag.map { String(format: "%.0f", $0) } ?? "-"
        let timeText = time.map { String(format: "%.1f", Double($0) / 1_000_000) } ?? "-"
        CaptureLog.capture.log("playback-echo \(new.rawValue, privacy: .public) run=\(CaptureLog.id(self.recordingID), privacy: .public) activeS=\(timeText, privacy: .public) peak=\(String(format: "%.3f", peak), privacy: .public) lagMs=\(lagText, privacy: .public)")
        onChange(new)
    }
}

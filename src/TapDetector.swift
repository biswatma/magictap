// TapDetector — turns a stream of accelerometer samples into tap events.
//
// A knock on the chassis shows up as a short, sharp transient riding on top of
// gravity. Gravity is tracked with a slow exponential average and subtracted,
// leaving linear acceleration; a tap is a local peak in the magnitude of that
// residual, above a threshold and outside a refractory window.
//
// Side classification uses corr(x, z): the Pearson correlation between the x
// and z waveforms across a window around the peak. Struck off-centre, the
// chassis pivots, so lateral and vertical motion couple with a sign that
// depends on which side of the pivot was hit — in phase for one side, anti-
// phase for the other.
//
// This replaces an earlier single-axis onset-sign test, which failed because
// vertical motion dominates every tap and the two sides are not mirror images
// (the IMU is not centred in the chassis). Measured over 42 labelled taps:
//
//     corr_xz    left mean +0.317   right mean -0.804   d' = 5.71   100%
//
// A correlation is scale-invariant, so tap force cannot leak into it — which
// matters, because the labelled sessions were not force-matched.
//
// See tools/analyze.py to re-derive the threshold on other hardware.

import Foundation

public enum TapSide: String {
    case left, right, unknown
}

public struct Tap {
    public let time: CFAbsoluteTime
    public let peak: Double
    public let peakVector: (x: Double, y: Double, z: Double)
    public let side: TapSide
    /// The discriminator, and a secondary feature kept for diagnostics.
    public let corrXZ: Double
    public let corrXY: Double
    /// Fraction of the window before the strike that was already in motion.
    /// Near zero for a tap on a still machine; high while the machine is being
    /// dragged, carried or jostled.
    public let backgroundActivity: Double
    public let sampleCount: Int
    public let sampleRate: Double
}

public struct TapConfig {
    /// Peak linear acceleration required to count as a tap, in g.
    public var threshold: Double = 0.06
    /// Minimum gap between accepted taps, in seconds.
    public var refractory: Double = 0.25
    /// Smoothing for the gravity estimate; smaller tracks orientation slower
    /// but leaks less of a tap into the baseline.
    public var gravityAlpha: Double = 0.01
    /// If the residual stays above the transient gate this long, the gravity
    /// estimate is resynced. Without this the estimate deadlocks: tilt or lift
    /// the machine and the residual never returns to zero, so gravity never
    /// re-learns and every sample reads as a tap forever. Must comfortably
    /// exceed the duration of a real tap, which is tens of milliseconds.
    public var gravityResyncAfter: Double = 0.35
    /// Samples averaged to seed gravity at startup. Seeding from one sample
    /// bakes in whatever motion happened to be underway at that instant.
    public var seedSamples: Int = 32
    /// How long before the peak is examined for surrounding motion.
    public var calmWindow: Double = 0.25
    /// Samples needed in the pre-window before the calm test is trusted. Too
    /// few and the verdict is meaningless, so the tap is allowed.
    public var calmMinSamples: Int = 24
    /// Sample-to-sample change above which the machine counts as moving.
    /// A still machine measures about 0.004 g between consecutive samples at
    /// 800 Hz; being dragged measures an order of magnitude more.
    public var motionGate: Double = 0.010
    /// Window around the peak used to compute the correlation features.
    public var preWindow: Double = 0.010
    public var postWindow: Double = 0.040
    /// corr(x, z) decision boundary; above it is "left" unless inverted.
    /// Midpoint of the two measured clusters.
    public var split: Double = -0.287
    /// Flip the left/right assignment.
    public var invert: Bool = false
    /// Minimum samples in the window before a side is asserted rather than
    /// reported as unknown.
    public var minWindowSamples: Int = 12

    public init() {}
}

public final class TapDetector {
    public var config: TapConfig

    private struct Entry {
        let v: (x: Double, y: Double, z: Double)
        let mag: Double
        /// Change since the previous sample. Independent of the gravity
        /// estimate, so it stays meaningful across a resync and while the
        /// baseline is still catching up to a new orientation.
        let delta: Double
        let t: CFAbsoluteTime
    }

    private var gravity: (x: Double, y: Double, z: Double)?
    private var seedSum: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var seedCount = 0
    /// When the residual first went above the transient gate, if it still is.
    private var elevatedSince: CFAbsoluteTime?
    private var previousSample: (x: Double, y: Double, z: Double)?
    /// Incremented on each forced resync, for diagnostics.
    public private(set) var resyncCount = 0
    private var history: [Entry] = []
    private var lastTapTime: CFAbsoluteTime = -.greatestFiniteMagnitude
    private var rate = RateMeter()
    private var currentRate: Double = 0

    /// Absolute sample index of a peak awaiting its post-window, and how many
    /// samples have been dropped from the front of `history`.
    private var candidate: Int?
    private var dropped = 0

    public init(config: TapConfig = TapConfig()) {
        self.config = config
    }

    /// Feeds one sample; returns a tap once its window is complete.
    public func process(_ s: MotionSample) -> Tap? {
        currentRate = rate.tick(s.time)

        // Seed from an average, so a machine that is moving at launch does not
        // permanently bias the baseline.
        guard var g = gravity else {
            seedSum = (seedSum.x + s.x, seedSum.y + s.y, seedSum.z + s.z)
            seedCount += 1
            if seedCount >= config.seedSamples {
                let n = Double(seedCount)
                gravity = (seedSum.x / n, seedSum.y / n, seedSum.z / n)
            }
            return nil
        }

        let linear = (x: s.x - g.x, y: s.y - g.y, z: s.z - g.z)
        let mag = (linear.x * linear.x + linear.y * linear.y + linear.z * linear.z).squareRoot()

        // Freeze the gravity estimate during a transient, otherwise a hard tap
        // partially absorbs itself into the baseline — but only briefly. A
        // sustained residual means the machine was tilted or picked up, not
        // tapped, and the baseline has to follow it or the detector jams.
        if mag < config.threshold * 0.5 {
            elevatedSince = nil
            let a = config.gravityAlpha
            g = (g.x + a * (s.x - g.x), g.y + a * (s.y - g.y), g.z + a * (s.z - g.z))
            gravity = g
        } else {
            let since = elevatedSince ?? s.time
            elevatedSince = since
            if s.time - since >= config.gravityResyncAfter {
                resync(to: s)
                return nil
            }
        }

        var delta = 0.0
        if let previous = previousSample {
            let dx = s.x - previous.x, dy = s.y - previous.y, dz = s.z - previous.z
            delta = (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        previousSample = (s.x, s.y, s.z)

        history.append(Entry(v: linear, mag: mag, delta: delta, t: s.time))
        trimHistory()

        let index = dropped + history.count - 1

        // Track the largest sample above threshold as the pending candidate.
        if mag >= config.threshold {
            if let c = candidate, let existing = entry(at: c) {
                if mag > existing.mag { candidate = index }
            } else {
                candidate = index
            }
        }

        // Emit once the post-window has elapsed.
        guard let c = candidate, let peak = entry(at: c),
              s.time - peak.t >= config.postWindow else { return nil }

        // A tap is a transient: the chassis rings and settles within tens of
        // milliseconds. If the residual is still elevated, this is a posture
        // change — tilted, picked up, resting on a lap — not a tap. Hold the
        // candidate rather than dropping it, so a real peak is not lost; a
        // genuinely sustained offset is cleared by the gravity resync instead.
        guard mag < config.threshold * 0.5 else { return nil }

        candidate = nil

        // Whether the machine was still beforehand is measured here but judged
        // by GestureRecognizer, which knows whether this tap starts a gesture
        // or completes one. The second tap of a double is preceded by the
        // first, and must not be penalised for it.
        let background = backgroundActivity(peak: peak)

        guard peak.t - lastTapTime >= config.refractory else { return nil }
        lastTapTime = peak.t

        return classify(peak: peak, backgroundActivity: background)
    }

    /// Fraction of the window before the peak that was already in motion.
    ///
    /// Measured as the proportion of samples whose sample-to-sample change
    /// exceeds `motionGate`, rather than the loudest residual: dragging
    /// produces continuous low-level motion that a single-maximum test misses,
    /// because each friction bump is still small next to the peak it precedes.
    /// Using the delta rather than the residual also keeps the measure honest
    /// while the gravity baseline is chasing a changing orientation.
    ///
    /// The window starts after the previous accepted tap's ringdown, so the
    /// second half of a deliberate double tap is not judged against the first.
    ///
    /// Too little history to judge reports 1 — treated as moving. Assuming
    /// stillness on no evidence is what let dragging through: a resync or a
    /// closely preceding tap truncates the window, and every leaked bump came
    /// from exactly that. The cost is that a tap in the first fraction of a
    /// second after launch is ignored.
    private func backgroundActivity(peak: Entry) -> Double {
        let guardBand = 0.02   // exclude the tap's own leading edge
        let start = max(peak.t - config.calmWindow, lastTapTime + config.refractory)
        let end = peak.t - guardBand
        guard end > start else { return 1 }

        let before = history.filter { $0.t >= start && $0.t <= end }
        guard before.count >= config.calmMinSamples else { return 1 }

        let moving = before.filter { $0.delta > config.motionGate }.count
        return Double(moving) / Double(before.count)
    }

    /// Snaps the baseline to the machine's current orientation and drops the
    /// in-flight detection state, so the move itself is not reported as a tap.
    private func resync(to sample: MotionSample) {
        gravity = (sample.x, sample.y, sample.z)
        elevatedSince = nil
        candidate = nil
        // History is deliberately kept. Its residuals are stale, but its
        // sample-to-sample deltas are not, and they are exactly the evidence
        // that the machine is in motion — which the next tap needs to see.
        resyncCount += 1
    }

    private func classify(peak: Entry, backgroundActivity: Double) -> Tap {
        let lo = peak.t - config.preWindow
        let hi = peak.t + config.postWindow
        let window = history.filter { $0.t >= lo && $0.t <= hi }

        let xs = window.map(\.v.x)
        let ys = window.map(\.v.y)
        let zs = window.map(\.v.z)
        let corrXZ = correlation(xs, zs)
        let corrXY = correlation(xs, ys)

        var side: TapSide = .unknown
        if window.count >= config.minWindowSamples {
            let isLeft = corrXZ > config.split
            side = (isLeft != config.invert) ? .left : .right
        }

        return Tap(time: peak.t,
                   peak: peak.mag,
                   peakVector: peak.v,
                   side: side,
                   corrXZ: corrXZ,
                   corrXY: corrXY,
                   backgroundActivity: backgroundActivity,
                   sampleCount: window.count,
                   sampleRate: currentRate)
    }

    private func entry(at absoluteIndex: Int) -> Entry? {
        let i = absoluteIndex - dropped
        guard i >= 0, i < history.count else { return nil }
        return history[i]
    }

    /// Keeps enough history for a full window plus margin, at any sample rate.
    private func trimHistory() {
        guard let newest = history.last else { return }
        let span = max((config.preWindow + config.postWindow) * 2 + 0.05,
                       config.calmWindow + config.postWindow + 0.05)
        let cutoff = newest.t - span
        var drop = 0
        while drop < history.count, history[drop].t < cutoff { drop += 1 }
        // Never discard the pending candidate.
        if let c = candidate {
            drop = min(drop, c - dropped)
        }
        if drop > 0 {
            history.removeFirst(drop)
            dropped += drop
        }
    }

    /// Pearson correlation. Scale-invariant, so tap force cannot influence it.
    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = a.count
        guard n > 2, n == b.count else { return 0 }
        let count = Double(n)
        let meanA = a.reduce(0, +) / count
        let meanB = b.reduce(0, +) / count
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<n {
            let da = a[i] - meanA
            let db = b[i] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }
        let denom = (varA * varB).squareRoot()
        return denom > 1e-12 ? cov / denom : 0
    }
}

// Calibration — derive the left/right decision boundary from labelled taps.
//
// The shipped default boundary (corr_xz = -0.287) was measured on one chassis,
// a MacBookPro18,4. A 13-inch Air is a different size, mass and stiffness, so
// it pivots differently and its two clusters sit somewhere else entirely. Any
// other model therefore needs its own boundary, and the only way to get one is
// to have the user tap each side a few times and measure.
//
// This is the same threshold search tools/analyze.py does offline, reduced to
// the one feature that won: given labelled corr_xz values, find the split and
// polarity that classify the most taps correctly, and report how well they
// actually separate so the user is told whether to trust the result.
//
// Deliberately pure and free of app state: the CLI can run it over recorded
// CSVs, which is how the maths is verified without needing to tap a machine.

import Foundation

public struct CalibrationResult {
    /// corr_xz decision boundary.
    public let split: Double
    /// Matches TapConfig.invert — false means corr_xz above the split is a
    /// left tap.
    public let invert: Bool

    /// Share of the calibration taps this boundary classifies correctly.
    public let accuracy: Double
    /// Separation in pooled standard deviations. Above ~2 is comfortable.
    public let dPrime: Double
    /// Distance from the boundary to the nearest calibration tap. A wide
    /// margin means the boundary is not balanced on a knife edge.
    public let margin: Double

    public let leftMean: Double
    public let rightMean: Double
    public let leftCount: Int
    public let rightCount: Int

    /// Detection threshold implied by how hard this user actually taps.
    public let suggestedThreshold: Double

    public enum Verdict: String {
        case excellent, good, weak

        public var summary: String {
            switch self {
            case .excellent: return "Excellent separation"
            case .good:      return "Usable separation"
            case .weak:      return "Weak separation"
            }
        }

        public var advice: String {
            switch self {
            case .excellent:
                return "Left and right taps are cleanly distinguishable on this Mac."
            case .good:
                return """
                    Left and right mostly work, with occasional mistakes. Tapping \
                    further from the trackpad, closer to the edge of the case, \
                    usually sharpens it.
                    """
            case .weak:
                return """
                    This Mac does not separate left from right reliably. Double \
                    tap still works perfectly — it ignores which side you hit — \
                    so bind your action to that and leave the single-tap \
                    bindings empty.
                    """
            }
        }
    }

    public var verdict: Verdict {
        if accuracy >= 0.95 && dPrime >= 2.0 { return .excellent }
        if accuracy >= 0.88 { return .good }
        return .weak
    }
}

public enum CalibrationError: Error, CustomStringConvertible {
    case tooFewLeft(have: Int, need: Int)
    case tooFewRight(have: Int, need: Int)
    case degenerate

    public var description: String {
        switch self {
        case .tooFewLeft(let have, let need):
            return "only \(have) left taps, need at least \(need)"
        case .tooFewRight(let have, let need):
            return "only \(have) right taps, need at least \(need)"
        case .degenerate:
            return "the taps carry no usable signal — every value was identical"
        }
    }
}

public enum Calibration {
    /// Taps required per side before a boundary is worth computing.
    public static let minimumPerSide = 6
    /// Taps requested per side by the guided flow, for a comfortable margin.
    public static let targetPerSide = 10

    /// Finds the boundary that classifies the most calibration taps correctly.
    ///
    /// - Parameters:
    ///   - leftCorr: corr_xz of each tap the user labelled left.
    ///   - rightCorr: corr_xz of each tap the user labelled right.
    ///   - peaks: peak magnitude of every calibration tap, either side, used
    ///     only to suggest a detection threshold.
    public static func compute(leftCorr: [Double],
                               rightCorr: [Double],
                               peaks: [Double]) throws -> CalibrationResult {
        guard leftCorr.count >= minimumPerSide else {
            throw CalibrationError.tooFewLeft(have: leftCorr.count, need: minimumPerSide)
        }
        guard rightCorr.count >= minimumPerSide else {
            throw CalibrationError.tooFewRight(have: rightCorr.count, need: minimumPerSide)
        }

        let all = (leftCorr + rightCorr).sorted()
        guard let low = all.first, let high = all.last, high - low > 1e-9 else {
            throw CalibrationError.degenerate
        }

        // Candidate boundaries: the midpoint between each adjacent pair of
        // observed values, plus a little outside each end so an all-one-side
        // split is still reachable.
        var candidates: [Double] = [low - 0.05, high + 0.05]
        for i in 1..<all.count where all[i] - all[i - 1] > 1e-12 {
            candidates.append((all[i] + all[i - 1]) / 2)
        }

        let total = Double(leftCorr.count + rightCorr.count)
        var best: (accuracy: Double, margin: Double, split: Double, invert: Bool)?

        for split in candidates {
            for invert in [false, true] {
                // Mirrors TapDetector.classify exactly: above the split is a
                // left tap unless inverted.
                let correct = leftCorr.filter { (($0 > split) != invert) }.count
                            + rightCorr.filter { (($0 > split) == invert) }.count
                let accuracy = Double(correct) / total
                let margin = all.map { abs($0 - split) }.min() ?? 0

                // Prefer accuracy, then the boundary furthest from any sample:
                // an equally accurate split sitting midway between the clusters
                // survives a tap that lands slightly off.
                if best == nil
                    || accuracy > best!.accuracy + 1e-12
                    || (abs(accuracy - best!.accuracy) <= 1e-12 && margin > best!.margin) {
                    best = (accuracy, margin, split, invert)
                }
            }
        }

        guard let winner = best else { throw CalibrationError.degenerate }

        let leftMean = mean(leftCorr)
        let rightMean = mean(rightCorr)
        let pooled = ((variance(leftCorr) + variance(rightCorr)) / 2).squareRoot()
        let dPrime = pooled > 1e-9 ? abs(leftMean - rightMean) / pooled : 0

        return CalibrationResult(
            split: winner.split,
            invert: winner.invert,
            accuracy: winner.accuracy,
            dPrime: dPrime,
            margin: winner.margin,
            leftMean: leftMean,
            rightMean: rightMean,
            leftCount: leftCorr.count,
            rightCount: rightCorr.count,
            suggestedThreshold: suggestThreshold(peaks: peaks))
    }

    /// A detection threshold scaled to how hard this user taps, so a light
    /// tapper on a stiff chassis is not left below the default.
    ///
    /// Set well under the typical tap so softer ones still register, and
    /// clamped: the floor stays clear of the ~0.005 g noise seen at rest, and
    /// the ceiling stops one unusually hard calibration run from raising the
    /// bar out of reach.
    static func suggestThreshold(peaks: [Double]) -> Double {
        let usable = peaks.filter { $0 > 0 }.sorted()
        guard !usable.isEmpty else { return 0.06 }
        let median = usable[usable.count / 2]
        return min(0.20, max(0.03, median * 0.30))
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        return values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
    }
}

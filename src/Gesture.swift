// Gesture — groups individual taps into single and double taps, and runs the
// shell command bound to each.
//
// A double tap is two taps within `doubleWindow`. It fires the moment the
// second tap is classified rather than waiting out the window, because nothing
// longer can follow it — only a *single* tap has to wait, to prove no second
// tap is coming.
//
// The lower bound on how fast two taps can be is TapConfig.refractory. That is
// not a free parameter: below about 0.12 s the ringdown of one hard tap starts
// registering as a second tap. Replaying the labelled sessions at successive
// values put the floor at 0.12 s (0.10 s turned 20 real taps into 25).

import Foundation

public enum Gesture {
    case single(TapSide)
    case double(TapSide, TapSide)

    public var name: String {
        switch self {
        case .single(let s): return "single-\(s.rawValue)"
        case .double: return "double"
        }
    }
}

/// What feeding a tap to the recogniser produced.
public enum TapOutcome {
    /// Discarded: the machine was already moving, so this is not a deliberate
    /// tap but one bump among many.
    case notIsolated(Double)
    /// Held, pending a possible second tap.
    case opened
    /// Completed a gesture.
    case gesture(Gesture)
}

public final class GestureRecognizer {
    /// Maximum gap between the two taps of a double tap.
    public var doubleWindow: Double = 0.45
    /// When false, a lone tap is discarded instead of being reported, so no
    /// single-tap latency is paid and stray knocks stay silent.
    public var wantsSingles: Bool

    /// Reject a gesture-opening tap when this fraction of the preceding window
    /// was already in motion. Deliberate taps on a still machine measure near
    /// zero; dragging it across a bed is in motion continuously.
    /// Measured on this hardware: deliberate taps reach at most 0.07, taps
    /// during dragging sit near 1.0.
    public var calmRatio: Double = 0.10
    /// Set false to accept every tap, for calibration.
    public var requireIsolation: Bool = true

    private var pending: Tap?

    public var hasPending: Bool { pending != nil }

    public init(wantsSingles: Bool) {
        self.wantsSingles = wantsSingles
    }

    /// Feeds a classified tap. A double tap completes on the second tap.
    public func feed(_ tap: Tap) -> TapOutcome {
        if let first = pending, tap.time - first.time <= doubleWindow {
            pending = nil
            return .gesture(.double(first.side, tap.side))
        }

        // Opening a gesture requires an isolated tap. A tap that merely
        // continues existing motion never becomes pending, so a stream of
        // bumps cannot pair up into a double.
        if requireIsolation && tap.backgroundActivity > calmRatio {
            pending = nil
            return .notIsolated(tap.backgroundActivity)
        }

        pending = tap
        return .opened
    }

    /// Call periodically. Emits a single tap once its window has closed with no
    /// second tap; a no-op when singles are unbound.
    public func expire(now: CFAbsoluteTime) -> Gesture? {
        guard let first = pending, now - first.time > doubleWindow else { return nil }
        pending = nil
        return wantsSingles ? .single(first.side) : nil
    }
}

/// Runs a shell command per gesture, without blocking the run loop.
public struct ActionRunner {
    public var singleLeft: String?
    public var singleRight: String?
    public var double: String?

    public init(singleLeft: String? = nil, singleRight: String? = nil, double: String? = nil) {
        self.singleLeft = singleLeft
        self.singleRight = singleRight
        self.double = double
    }

    public var wantsSingles: Bool { singleLeft != nil || singleRight != nil }

    public func command(for gesture: Gesture) -> String? {
        switch gesture {
        case .double: return double
        case .single(.left): return singleLeft
        case .single(.right): return singleRight
        case .single(.unknown): return nil
        }
    }

    /// Launches the command and returns without waiting, so a slow or
    /// interactive action cannot stall sample delivery.
    @discardableResult
    public func run(_ gesture: Gesture) -> Bool {
        guard let cmd = command(for: gesture) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["MAGICTAP_GESTURE"] = gesture.name
        if case .single(let side) = gesture { env["MAGICTAP_SIDE"] = side.rawValue }
        process.environment = env
        do {
            try process.run()
            return true
        } catch {
            FileHandle.standardError.write("action failed: \(error)\n".data(using: .utf8)!)
            return false
        }
    }
}

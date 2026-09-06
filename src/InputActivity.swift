// InputActivity — suppresses taps that are really keystrokes or trackpad clicks.
//
// Typing is a series of impacts on the same chassis the accelerometer reads, so
// keystrokes land well above the tap threshold and two of them inside the
// double-tap window look exactly like a deliberate double tap. Left unguarded,
// the app fires continuously while you type.
//
// The fix is to ask the window server how long it has been since real input.
// CGEventSource.secondsSinceLastEventType needs no Accessibility or Input
// Monitoring permission — it reports timing only, never content or keycodes.
//
// This lives outside TapDetector on purpose: the detector stays a pure function
// of the sample stream, so `magictap replay` remains deterministic and its
// 40/40 score keeps meaning something.

import Foundation
import CoreGraphics

public enum InputActivity {
    /// Impact-like events only. Pointer motion and scrolling are excluded —
    /// fingers sliding on glass do not thump the case, and including them would
    /// suppress taps whenever a finger rested on the trackpad.
    private static let impactEvents: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown,
    ]

    /// Seconds since the most recent keystroke or click, or `.infinity` if the
    /// window server has nothing to report.
    public static func secondsSinceLastInput() -> Double {
        var best = Double.infinity
        for type in impactEvents {
            let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                  eventType: type)
            // A session with no such event yet reports a very large value.
            if seconds >= 0, seconds < best { best = seconds }
        }
        return best
    }
}

/// Decides whether a detected tap should be allowed to act.
public struct TapGate {
    public enum Rejection: String {
        case typing
        case cooldown

        public var explanation: String {
            switch self {
            case .typing: return "ignored — keyboard or trackpad in use"
            case .cooldown: return "ignored — too soon after the last action"
            }
        }
    }

    /// Taps within this long of a keystroke or click are ignored.
    public var inputWindow: Double = 0.35
    /// Taps within this long of a fired action are ignored, so an action that
    /// disturbs the machine cannot retrigger itself.
    public var cooldown: Double = 0.70
    /// Set false to accept every tap, for calibration.
    public var enabled: Bool = true

    private var blockedUntil: CFAbsoluteTime = 0

    public init() {}

    /// Returns nil to accept the tap, or why it was rejected.
    public func evaluate(at time: CFAbsoluteTime) -> Rejection? {
        guard enabled else { return nil }
        if time < blockedUntil { return .cooldown }
        if InputActivity.secondsSinceLastInput() < inputWindow { return .typing }
        return nil
    }

    /// Call after an action runs, to open the cooldown.
    public mutating func noteActionFired(at time: CFAbsoluteTime) {
        blockedUntil = time + cooldown
    }
}

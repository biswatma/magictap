// CalibrationSession — drives the guided left/right calibration flow.
//
// Collects a run of taps labelled left, then a run labelled right, hands both
// to Calibration.compute and holds the result for review. Taps arrive from
// TapEngine's calibration sink, so no gesture forms and no action fires while
// this is running.

import Foundation
import AppKit
import Combine

final class CalibrationSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case collecting(TapSide)
        case review
        case applied
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var leftTaps: [Tap] = []
    @Published private(set) var rightTaps: [Tap] = []
    @Published private(set) var result: CalibrationResult?
    @Published private(set) var problem: String?
    /// Taps rejected during collection, with the reason, so a user whose taps
    /// are being discarded is told why rather than watching a counter stall.
    @Published private(set) var rejected: String?

    /// Also raise the detection threshold to match how hard this user taps.
    @Published var updateThreshold = true

    let target = Calibration.targetPerSide
    let minimum = Calibration.minimumPerSide

    private let engine = TapEngine.shared

    // MARK: - Progress

    var collected: [Tap] {
        if case .collecting(.left) = phase { return leftTaps }
        if case .collecting(.right) = phase { return rightTaps }
        return []
    }

    var canAdvance: Bool { collected.count >= minimum }

    var instruction: String {
        switch phase {
        case .collecting(.left):
            return "Tap the case to the LEFT of the trackpad"
        case .collecting(.right):
            return "Tap the case to the RIGHT of the trackpad"
        default:
            return ""
        }
    }

    // MARK: - Flow

    func start() {
        leftTaps = []
        rightTaps = []
        result = nil
        problem = nil
        rejected = nil
        beginCollecting(.left)
    }

    /// Moves from the left run to the right run, or from the right run to the
    /// computed result.
    func advance() {
        switch phase {
        case .collecting(.left):
            beginCollecting(.right)
        case .collecting(.right):
            finish()
        default:
            break
        }
    }

    func cancel() {
        engine.calibrationSink = nil
        phase = .idle
        problem = nil
        rejected = nil
    }

    func apply() {
        guard let result else { return }
        Settings.shared.applyCalibration(result, updateThreshold: updateThreshold)
        engine.applySettings()
        Log.write(String(format: "calibrated: split=%+.3f invert=%@ accuracy=%.0f%% (%d left, %d right)",
                         result.split, result.invert ? "yes" : "no",
                         result.accuracy * 100, result.leftCount, result.rightCount))
        phase = .applied
    }

    func resetToDefault() {
        Settings.shared.resetCalibration()
        engine.applySettings()
        Log.write("calibration reset to the shipped default")
        result = nil
        phase = .idle
    }

    // MARK: - Collection

    private func beginCollecting(_ side: TapSide) {
        phase = .collecting(side)
        rejected = nil
        engine.calibrationSink = { [weak self] tap in
            self?.accept(tap, for: side)
        }
    }

    /// A calibration tap must be as clean as a real one, or the boundary is
    /// derived from noise. The same isolation rule the recogniser applies to
    /// gesture-opening taps is applied here.
    private func accept(_ tap: Tap, for side: TapSide) {
        guard case .collecting(let current) = phase, current == side else { return }

        if tap.backgroundActivity > 0.25 {
            rejected = "ignored a tap — the Mac was moving. Rest it on something solid."
            return
        }
        if InputActivity.secondsSinceLastInput() < 0.35 {
            rejected = "ignored a tap — that was keyboard or trackpad input."
            return
        }

        rejected = nil
        switch side {
        case .left:  leftTaps.append(tap)
        case .right: rightTaps.append(tap)
        case .unknown: return
        }

        if Settings.shared.playFeedback {
            NSSound(named: "Tink")?.play()
        }

        // Enough for a comfortable margin — move on without making the user
        // hunt for the button.
        if collected.count >= target {
            advance()
        }
    }

    private func finish() {
        engine.calibrationSink = nil
        do {
            result = try Calibration.compute(
                leftCorr: leftTaps.map(\.corrXZ),
                rightCorr: rightTaps.map(\.corrXZ),
                peaks: (leftTaps + rightTaps).map(\.peak))
            updateThreshold = true
            problem = nil
            phase = .review
        } catch {
            problem = "\(error)"
            phase = .review
        }
    }
}

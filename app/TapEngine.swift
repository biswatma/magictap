// TapEngine — owns the sensor and turns gestures into actions.
//
// Wraps the same MotionSource / TapDetector / GestureRecognizer / TapGate used
// by the CLI, and publishes enough state for the menu bar and setup window to
// show what is happening.

import Foundation
import AppKit
import Combine

final class TapEngine: ObservableObject {
    static let shared = TapEngine()

    enum Status: Equatable {
        case stopped
        case unsupported(String)
        case running

        var isRunning: Bool { self == .running }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastEvent: String = "—"
    @Published private(set) var tapCount = 0
    @Published private(set) var gestureCount = 0
    /// Set when an action was blocked for want of Screen Recording.
    @Published private(set) var blockedOnPermission = false
    /// Most recent taps, newest first, for the live monitor in setup.
    @Published private(set) var recentTaps: [String] = []
    /// Taps rejected as typing or as too soon after an action.
    @Published private(set) var suppressedCount = 0

    private var source: MotionSource?
    private var detector = TapDetector()
    private var gestures = GestureRecognizer(wantsSingles: false)
    private var gate = TapGate()

    /// The setup window is opened at most once per launch when permission is
    /// missing. Reopening it on every tap would be its own kind of spam.
    private var permissionNoticeShown = false

    /// While set, taps are handed here instead of forming gestures, and no
    /// action fires. Calibration needs the raw taps, and firing a screenshot
    /// on every calibration tap would be its own small disaster.
    var calibrationSink: ((Tap) -> Void)?

    var onPermissionNeeded: (() -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }

        let source = MotionSource(kind: .accelerometer)
        do {
            try source.connect()
        } catch {
            status = .unsupported("\(error)")
            Log.write("sensor unavailable: \(error)")
            return
        }
        self.source = source

        applySettings()
        source.requestInterval(microseconds: 1250)  // 800 Hz

        source.start { [weak self] sample in
            self?.handle(sample)
        }
        status = .running
        Log.write("engine started — sensor \(sensorDescription)")
    }

    /// The HID event system has no unsubscribe in this wrapper, so "stopping"
    /// gates delivery rather than tearing the client down. Cheap, and it keeps
    /// re-enabling instant.
    func setEnabled(_ on: Bool) {
        Settings.shared.enabled = on
        Log.write(on ? "enabled" : "paused")
        if on && !status.isRunning { start() }
        objectWillChange.send()
    }

    /// Re-reads settings into the detector without restarting the sensor.
    func applySettings() {
        let s = Settings.shared
        var config = TapConfig()
        config.threshold = s.threshold
        config.refractory = 0.12  // measured floor before ringdown re-triggers
        config.invert = s.invertSides
        config.split = s.split    // chassis specific; see Calibration
        detector.config = config

        gate.enabled = s.inputGuard
        gestures.doubleWindow = s.doubleWindow
        gestures.wantsSingles = s.leftAction != .none || s.rightAction != .none
        gestures.requireIsolation = s.motionGuard
    }

    /// Called after the user grants permission, to clear the warning state.
    func recheckPermission() {
        let satisfied = Permissions.screenRecordingGranted && Permissions.accessibilityGranted
        if satisfied && blockedOnPermission {
            blockedOnPermission = false
            permissionNoticeShown = false
            lastEvent = "permission granted"
        }
    }

    // MARK: - Sample handling

    private func handle(_ sample: MotionSample) {
        // Calibration takes priority: no gesture grouping, no actions, and the
        // enabled switch does not gate it, so a paused app can still calibrate.
        if let sink = calibrationSink {
            if let tap = detector.process(sample) { sink(tap) }
            return
        }

        if let gesture = gestures.expire(now: sample.time) {
            fire(gesture)
        }
        guard let tap = detector.process(sample) else { return }
        guard Settings.shared.enabled else { return }

        // Gate before gesture grouping: a keystroke paired with a real tap
        // would otherwise form a double tap.
        if let reason = gate.evaluate(at: tap.time) {
            suppressedCount += 1
            show(String(format: "%@  %.2f g  %@", tap.side.rawValue, tap.peak, reason.explanation))
            Log.write(String(format: "tap ignored (%@) side=%@ peak=%.3f",
                             reason.rawValue, tap.side.rawValue, tap.peak))
            return
        }

        tapCount += 1
        show(String(format: "%@  %.2f g  corr %+.2f", tap.side.rawValue, tap.peak, tap.corrXZ))
        Log.write(String(format: "tap side=%@ peak=%.3f corr_xz=%+.3f",
                         tap.side.rawValue, tap.peak, tap.corrXZ))

        switch gestures.feed(tap) {
        case .gesture(let gesture):
            fire(gesture)
        case .notIsolated(let activity):
            suppressedCount += 1
            show(String(format: "%@  %.2f g  ignored — Mac was moving", tap.side.rawValue, tap.peak))
            Log.write(String(format: "tap ignored (moving) side=%@ peak=%.3f activity=%.2f",
                             tap.side.rawValue, tap.peak, activity))
        case .opened:
            break
        }
    }

    private func show(_ line: String) {
        recentTaps.insert(line, at: 0)
        if recentTaps.count > 8 { recentTaps.removeLast() }
    }

    // MARK: - Actions

    private func binding(for gesture: Gesture) -> (action: ActionID, custom: String) {
        let s = Settings.shared
        switch gesture {
        case .double:         return (s.doubleAction, s.customDouble)
        case .single(.left):  return (s.leftAction, s.customLeft)
        case .single(.right): return (s.rightAction, s.customRight)
        case .single(.unknown): return (.none, "")
        }
    }

    private func fire(_ gesture: Gesture) {
        guard Settings.shared.enabled else { return }
        gestureCount += 1

        let (action, parameter) = binding(for: gesture)
        guard action != .none else {
            lastEvent = "\(gesture.name) — no action bound"
            Log.write("gesture \(gesture.name) — no action bound")
            return
        }

        // Never start an action whose permission is missing. Launching it
        // anyway is what made the system prompt reappear on every tap.
        if action.needsScreenRecording && !Permissions.screenRecordingGranted {
            blockOn("Screen Recording", gesture: gesture)
            return
        }
        if action.needsAccessibility && !Permissions.accessibilityGranted {
            blockOn("Accessibility", gesture: gesture)
            return
        }

        // Open the cooldown before acting, so a slow action cannot be
        // retriggered while it is still running.
        gate.noteActionFired(at: CFAbsoluteTimeGetCurrent())
        lastEvent = "\(gesture.name) — \(action.title)"
        Log.write("gesture \(gesture.name) — \(action.title)")

        Task { [action, parameter] in
            do {
                try await ActionExecutor.perform(action, parameter: parameter)
                await MainActor.run { self.succeeded() }
            } catch {
                await MainActor.run { self.failed("\(error)") }
            }
        }
    }

    private func blockOn(_ permission: String, gesture: Gesture) {
        blockedOnPermission = true
        lastEvent = "\(gesture.name) — needs \(permission)"
        Log.write("gesture \(gesture.name) blocked — \(permission) not granted")
        if !permissionNoticeShown {
            permissionNoticeShown = true
            onPermissionNeeded?()
        }
    }

    private func succeeded() {
        if Settings.shared.playFeedback {
            NSSound(named: "Pop")?.play()
        }
    }

    private func failed(_ message: String) {
        lastEvent = "failed — \(message)"
        Log.write("action failed: \(message)")
        NSSound(named: "Funk")?.play()
    }

    // MARK: - Diagnostics

    var sensorDescription: String {
        guard let props = source?.describeService(), let model = props["model"] else {
            return "not detected"
        }
        let maker = props["manufacturer"] ?? ""
        return "\(model)\(maker.isEmpty ? "" : " (\(maker))")"
    }
}

// Support — persisted settings, permission checks, and login-item handling.

import Foundation
import AppKit
import CoreGraphics
import ServiceManagement
import ApplicationServices

// MARK: - Settings

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let doubleAction = "doubleAction"
        static let leftAction = "leftAction"
        static let rightAction = "rightAction"
        static let customDouble = "customDoubleCommand"
        static let customLeft = "customLeftCommand"
        static let customRight = "customRightCommand"
        static let threshold = "threshold"
        static let doubleWindow = "doubleWindow"
        static let invertSides = "invertSides"
        static let playFeedback = "playFeedback"
        static let onboarded = "onboardingComplete"
        static let inputGuard = "inputGuard"
        static let motionGuard = "motionGuard"
        static let split = "corrSplit"
        static let calibratedAt = "calibratedAt"
        static let calibratedAccuracy = "calibratedAccuracy"
        static let calibratedLeftCount = "calibratedLeftCount"
        static let calibratedRightCount = "calibratedRightCount"
        static let calibratedVerdict = "calibratedVerdict"
    }

    /// The boundary MagicTap ships with, measured on a MacBookPro18,4. Any
    /// other model should calibrate; this is only a starting point.
    static let defaultSplit = -0.287

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.doubleAction: ActionID.screenshotClipboard.rawValue,
            Key.leftAction: ActionID.none.rawValue,
            Key.rightAction: ActionID.none.rawValue,
            Key.threshold: 0.06,
            Key.doubleWindow: 0.45,
            Key.invertSides: false,
            Key.playFeedback: true,
            Key.onboarded: false,
            Key.inputGuard: true,
            Key.motionGuard: true,
            Key.split: Settings.defaultSplit,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var doubleAction: ActionID {
        get { ActionID(rawValue: defaults.string(forKey: Key.doubleAction) ?? "") ?? .screenshotClipboard }
        set { defaults.set(newValue.rawValue, forKey: Key.doubleAction) }
    }

    var leftAction: ActionID {
        get { ActionID(rawValue: defaults.string(forKey: Key.leftAction) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Key.leftAction) }
    }

    var rightAction: ActionID {
        get { ActionID(rawValue: defaults.string(forKey: Key.rightAction) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Key.rightAction) }
    }

    var customDouble: String {
        get { defaults.string(forKey: Key.customDouble) ?? "" }
        set { defaults.set(newValue, forKey: Key.customDouble) }
    }

    var customLeft: String {
        get { defaults.string(forKey: Key.customLeft) ?? "" }
        set { defaults.set(newValue, forKey: Key.customLeft) }
    }

    var customRight: String {
        get { defaults.string(forKey: Key.customRight) ?? "" }
        set { defaults.set(newValue, forKey: Key.customRight) }
    }

    var threshold: Double {
        get { defaults.double(forKey: Key.threshold) }
        set { defaults.set(newValue, forKey: Key.threshold) }
    }

    var doubleWindow: Double {
        get { defaults.double(forKey: Key.doubleWindow) }
        set { defaults.set(newValue, forKey: Key.doubleWindow) }
    }

    var invertSides: Bool {
        get { defaults.bool(forKey: Key.invertSides) }
        set { defaults.set(newValue, forKey: Key.invertSides) }
    }

    var playFeedback: Bool {
        get { defaults.bool(forKey: Key.playFeedback) }
        set { defaults.set(newValue, forKey: Key.playFeedback) }
    }

    /// Ignore taps that coincide with typing or trackpad clicks. On by
    /// default: keystrokes are impacts on the same chassis, so without this the
    /// app fires continuously while you type.
    var inputGuard: Bool {
        get { defaults.bool(forKey: Key.inputGuard) }
        set { defaults.set(newValue, forKey: Key.inputGuard) }
    }

    /// Ignore taps that arrive while the Mac is already in motion. On by
    /// default: dragging the machine across a bed produces friction bumps that
    /// individually look exactly like taps.
    var motionGuard: Bool {
        get { defaults.bool(forKey: Key.motionGuard) }
        set { defaults.set(newValue, forKey: Key.motionGuard) }
    }

    /// corr_xz boundary separating a left tap from a right one. Chassis
    /// specific — see Calibration.
    var split: Double {
        get { defaults.double(forKey: Key.split) }
        set { defaults.set(newValue, forKey: Key.split) }
    }

    /// Nil until the user has run calibration on this machine.
    var calibratedAt: Date? {
        get { defaults.object(forKey: Key.calibratedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.calibratedAt) }
    }

    var calibratedAccuracy: Double {
        get { defaults.double(forKey: Key.calibratedAccuracy) }
        set { defaults.set(newValue, forKey: Key.calibratedAccuracy) }
    }

    var calibratedLeftCount: Int {
        get { defaults.integer(forKey: Key.calibratedLeftCount) }
        set { defaults.set(newValue, forKey: Key.calibratedLeftCount) }
    }

    var calibratedRightCount: Int {
        get { defaults.integer(forKey: Key.calibratedRightCount) }
        set { defaults.set(newValue, forKey: Key.calibratedRightCount) }
    }

    var calibratedVerdict: String {
        get { defaults.string(forKey: Key.calibratedVerdict) ?? "" }
        set { defaults.set(newValue, forKey: Key.calibratedVerdict) }
    }

    /// Stores a calibration result as the machine's active configuration.
    func applyCalibration(_ result: CalibrationResult, updateThreshold: Bool) {
        split = result.split
        invertSides = result.invert
        if updateThreshold { threshold = result.suggestedThreshold }
        calibratedAt = Date()
        calibratedAccuracy = result.accuracy
        calibratedLeftCount = result.leftCount
        calibratedRightCount = result.rightCount
        calibratedVerdict = result.verdict.rawValue
    }

    /// Returns to the shipped boundary, discarding any calibration.
    func resetCalibration() {
        split = Settings.defaultSplit
        invertSides = false
        calibratedAt = nil
        calibratedAccuracy = 0
        calibratedLeftCount = 0
        calibratedRightCount = 0
        calibratedVerdict = ""
    }

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

}

// MARK: - Log

/// A small rolling log, so a menu bar app with no console is still diagnosable.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MagicTap.log")
    }()

    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.biswa.magictap.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "\(stamp.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? data.write(to: url)
                return
            }
            // Rotate by truncating rather than growing without bound.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? fm.removeItem(at: url)
                try? data.write(to: url)
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) {
            write("log opened")
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Permissions

enum Permissions {
    /// Screen Recording, which screencapture needs. Without it screencapture
    /// does not error — it silently returns the desktop picture with no
    /// windows, so this has to be checked rather than discovered.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts once. macOS only shows the dialog the first time; afterwards the
    /// user has to toggle it in System Settings, so callers should follow up by
    /// opening the pane.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Accessibility, needed to synthesise keystrokes and to move another
    /// app's windows. Unlike Screen Recording this has no preflight that is
    /// separate from the prompt, so `prompt: false` checks without asking.
    static var accessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// The motion sensor needs no TCC permission, but it does need hardware
    /// that only exists on Apple silicon MacBooks from the 2021/2022 redesigns.
    static func sensorAvailable() -> Bool {
        let probe = MotionSource(kind: .accelerometer)
        return (try? probe.connect()) != nil
    }
}

// MARK: - Login item

enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

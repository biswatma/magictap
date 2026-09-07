// SetupWindow — permission onboarding, instructions, and settings.

import SwiftUI
import AppKit

// MARK: - Root

/// Which tab the setup window shows, shared so the menu bar can target one.
final class SetupNavigation: ObservableObject {
    static let shared = SetupNavigation()
    @Published var tab: SetupView.Tab = .setup
    private init() {}
}

struct SetupView: View {
    @ObservedObject var engine = TapEngine.shared
    @ObservedObject var nav = SetupNavigation.shared
    @StateObject private var calibration = CalibrationSession()

    enum Tab { case setup, calibrate, settings }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $nav.tab) {
                Text("Setup").tag(Tab.setup)
                Text("Calibrate").tag(Tab.calibrate)
                Text("Settings").tag(Tab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch nav.tab {
                    case .setup:     SetupTab(engine: engine)
                    case .calibrate: CalibrateTab(session: calibration)
                    case .settings:  SettingsTab(engine: engine)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 600)
        // Leaving the tab mid-run would otherwise keep the sink installed and
        // silently swallow every tap.
        .onChange(of: nav.tab) { _, newTab in
            if newTab != .calibrate { calibration.cancel() }
        }
    }
}

// MARK: - Setup

struct SetupTab: View {
    @ObservedObject var engine: TapEngine
    @State private var screenGranted = Permissions.screenRecordingGranted
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var promptShown = false

    /// Permission changes land outside the app, so the state is polled.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var boundActions: [ActionID] {
        [Settings.shared.doubleAction, Settings.shared.leftAction, Settings.shared.rightAction]
    }
    private var needsScreen: Bool { boundActions.contains { $0.needsScreenRecording } }
    private var needsAX: Bool { boundActions.contains { $0.needsAccessibility } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MagicTap").font(.title2).bold()
                    Text("Tap the case beside the trackpad to trigger an action.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            StepCard(
                number: 1,
                title: "Motion sensor",
                ok: engine.status.isRunning,
                detail: sensorDetail
            ) {
                if case .unsupported = engine.status {
                    Text("""
                        MagicTap needs the IMU that Apple silicon MacBooks got \
                        with the 2021 MacBook Pro and 2022 MacBook Air. Intel \
                        Macs, the M1 Air and the M1 13-inch Pro do not have it.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if engine.blockedOnPermission && !screenGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("A tap was detected but the screenshot could not run — "
                         + "grant Screen Recording below.")
                        .font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            StepCard(
                number: 2,
                title: "Screen Recording",
                ok: screenGranted || !needsScreen,
                detail: screenDetail
            ) {
                if needsScreen && !screenGranted {
                    Text("""
                        Screenshots need this. Without it macOS does not show an \
                        error — screencapture just returns your desktop picture \
                        with no windows in it.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button("Grant Permission") {
                            Permissions.requestScreenRecording()
                            promptShown = true
                            // The dialog only ever appears once; after that the
                            // pane is the only route.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                if !Permissions.screenRecordingGranted {
                                    Permissions.openScreenRecordingSettings()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Settings") { Permissions.openScreenRecordingSettings() }
                    }

                    if promptShown {
                        Text("""
                            Enable MagicTap in the list, then quit and reopen it. \
                            macOS only applies the change to a fresh launch.
                            """)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            StepCard(
                number: 3,
                title: "Accessibility",
                ok: axGranted || !needsAX,
                detail: !needsAX ? "not needed for the current actions"
                                 : (axGranted ? "granted" : "not granted")
            ) {
                if needsAX && !axGranted {
                    Text("""
                        Keyboard shortcuts, media keys and window management work \
                        by synthesising input, which macOS gates behind \
                        Accessibility. Screenshots and volume do not need it.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button("Grant Permission") {
                            Permissions.requestAccessibility()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                if !Permissions.accessibilityGranted {
                                    Permissions.openAccessibilitySettings()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            }

            StepCard(number: 4, title: "How to use", ok: true, detail: "Double tap to fire") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Double tap the case to the left or right of the trackpad.",
                          systemImage: "hand.tap")
                    Label("Tap the case, not the trackpad — a firm knuckle tap works best.",
                          systemImage: "info.circle")
                    Label("MagicTap lives in the menu bar. Quit it from there.",
                          systemImage: "menubar.arrow.up.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Live tap monitor").font(.headline)
                Text("Tap now to check detection. \(engine.tapCount) taps, "
                     + "\(engine.gestureCount) gestures"
                     + (engine.suppressedCount > 0
                        ? ", \(engine.suppressedCount) ignored while typing" : "")
                     + " this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Take your hands off the keyboard before tapping — taps "
                     + "during typing are ignored on purpose.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if engine.recentTaps.isEmpty {
                    Text("No taps yet")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(engine.recentTaps.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .onReceive(tick) { _ in
            screenGranted = Permissions.screenRecordingGranted
            axGranted = Permissions.accessibilityGranted
            engine.recheckPermission()
        }
    }

    private var sensorDetail: String {
        switch engine.status {
        case .running: return engine.sensorDescription
        case .stopped: return "starting…"
        case .unsupported: return "not available on this Mac"
        }
    }

    private var screenDetail: String {
        if !needsScreen { return "not needed for the current actions" }
        return screenGranted ? "granted" : "not granted"
    }
}


// MARK: - Calibrate

struct CalibrateTab: View {
    @ObservedObject var session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calibrate left and right").font(.title3).bold()
                Text("""
                    MagicTap ships with a boundary measured on one machine, a \
                    16-inch MacBook Pro. A different size, mass and stiffness \
                    pivots differently when struck, so its left and right taps \
                    land somewhere else entirely. Tap each side a few times and \
                    MagicTap will work out the boundary for your Mac.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            switch session.phase {
            case .idle:
                idle
            case .collecting:
                collecting
            case .review:
                review
            case .applied:
                applied
            }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 16) {
            currentStatus

            Button("Start calibration") { session.start() }
                .buttonStyle(.borderedProminent)

            Text("""
                Rest the Mac on a desk, take your hands off the keyboard, and \
                tap the case itself rather than the trackpad. \
                \(session.target) taps a side.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if Settings.shared.calibratedAt != nil {
                Button("Reset to the shipped default") { session.resetToDefault() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var currentStatus: some View {
        let s = Settings.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: s.calibratedAt == nil
                      ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(s.calibratedAt == nil ? .orange : .green)
                Text(s.calibratedAt == nil
                     ? "Not calibrated for this Mac"
                     : "Calibrated for this Mac")
                    .font(.headline)
            }
            if let at = s.calibratedAt {
                Text(String(format: "%.0f%% accurate on %d left and %d right taps · %@",
                            s.calibratedAccuracy * 100, s.calibratedLeftCount,
                            s.calibratedRightCount,
                            at.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Using the shipped boundary. Accurate on the machine it was "
                     + "measured on; unverified on yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "boundary corr_xz %+.3f%@", s.split,
                        s.invertSides ? " (inverted)" : ""))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Collecting

    private var collecting: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.instruction)
                .font(.title2).bold()
                .foregroundStyle(.tint)

            HStack(spacing: 6) {
                ForEach(0..<session.target, id: \.self) { i in
                    Circle()
                        .fill(i < session.collected.count ? Color.accentColor : Color.gray.opacity(0.25))
                        .frame(width: 12, height: 12)
                }
                Text("\(session.collected.count) of \(session.target)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }

            if let rejected = session.rejected {
                Label(rejected, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !session.collected.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(session.collected.suffix(5).enumerated()), id: \.offset) { _, tap in
                        Text(String(format: "%.2f g   corr %+.2f", tap.peak, tap.corrXZ))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button(session.canAdvance ? "Next" : "Next (need \(session.minimum))") {
                    session.advance()
                }
                .disabled(!session.canAdvance)
                Button("Cancel") { session.cancel() }
            }
        }
    }

    // MARK: Review

    @ViewBuilder
    private var review: some View {
        if let problem = session.problem {
            VStack(alignment: .leading, spacing: 14) {
                Label("Calibration could not be computed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.headline)
                Text(problem).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Try again") { session.start() }.buttonStyle(.borderedProminent)
                    Button("Cancel") { session.cancel() }
                }
            }
        } else if let r = session.result {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: r.verdict == .weak
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(r.verdict == .weak ? .orange : .green)
                    Text(r.verdict.summary).font(.headline)
                }

                Text(r.verdict.advice).font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 7) {
                    metric("Accuracy", String(format: "%.0f%%", r.accuracy * 100),
                           "of your \(r.leftCount + r.rightCount) calibration taps")
                    metric("Separation", String(format: "d′ %.2f", r.dPrime),
                           "above 2.0 is comfortable")
                    metric("Boundary", String(format: "%+.3f", r.split),
                           String(format: "%.3f clear of the nearest tap", r.margin))
                    metric("Clusters", String(format: "%+.2f / %+.2f", r.leftMean, r.rightMean),
                           "left / right averages")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                Toggle(isOn: Binding(get: { session.updateThreshold },
                                     set: { session.updateThreshold = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Also set tap strength to %.3f g",
                                    r.suggestedThreshold))
                        Text("Scaled to how hard you tapped, with headroom for softer taps.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Apply") { session.apply() }.buttonStyle(.borderedProminent)
                    Button("Redo") { session.start() }
                    Button("Cancel") { session.cancel() }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).bold()
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Applied

    private var applied: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Calibration applied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
            Text("Tap either side of the trackpad to try it. The live monitor on "
                 + "the Setup tab shows which side MagicTap thinks you hit.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Calibrate again") { session.start() }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var engine: TapEngine

    @State private var doubleAction: ActionID = Settings.shared.doubleAction
    @State private var leftAction: ActionID = Settings.shared.leftAction
    @State private var rightAction: ActionID = Settings.shared.rightAction
    @State private var customDouble = Settings.shared.customDouble
    @State private var customLeft = Settings.shared.customLeft
    @State private var customRight = Settings.shared.customRight
    @State private var threshold = Settings.shared.threshold
    @State private var doubleWindow = Settings.shared.doubleWindow
    @State private var invert = Settings.shared.invertSides
    @State private var inputGuard = Settings.shared.inputGuard
    @State private var motionGuard = Settings.shared.motionGuard
    @State private var feedback = Settings.shared.playFeedback
    @State private var launchAtLogin = LoginItem.enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Gestures") {
                actionRow("Double tap", $doubleAction, $customDouble)
                Divider()
                actionRow("Single tap, left", $leftAction, $customLeft)
                actionRow("Single tap, right", $rightAction, $customRight)
                Text("""
                    Single taps wait out the double-tap window to prove no second \
                    tap follows, so leaving them off keeps stray knocks silent.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("Sensitivity") {
                LabeledContent("Tap strength") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: $threshold, in: 0.02...0.25) { _ in commit() }
                            .frame(width: 220)
                        Text(String(format: "%.3f g — lower detects softer taps", threshold))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Double-tap window") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: $doubleWindow, in: 0.20...0.80) { _ in commit() }
                            .frame(width: 220)
                        Text(String(format: "%.2f s between the two taps", doubleWindow))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Toggle("Swap left and right", isOn: committing($invert))

                Toggle("Ignore taps while the Mac is moving", isOn: committing($motionGuard))
                Text("""
                    A deliberate tap is isolated: the case is still, then \
                    struck. Dragging the Mac across a bed or desk produces \
                    friction bumps that each look like a tap on their own.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Ignore taps while typing", isOn: committing($inputGuard))
                Text("""
                    Keystrokes and trackpad clicks are impacts on the same case \
                    the sensor reads, so two of them inside the double-tap \
                    window look exactly like a double tap. Leave this on unless \
                    you are calibrating.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("General") {
                Toggle("Play a sound when an action runs", isOn: committing($feedback))
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            try LoginItem.set(on)
                            launchAtLogin = on
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.enabled
                        }
                    }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ label: String,
                           _ action: Binding<ActionID>,
                           _ parameter: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: committing(action)) {
                Text(ActionID.none.title).tag(ActionID.none)
                ForEach(ActionGroup.allCases.filter { $0 != .none }) { group in
                    Section(group.rawValue) {
                        ForEach(group.actions) { a in Text(a.title).tag(a) }
                    }
                }
            }
            .pickerStyle(.menu)

            if let prompt = action.wrappedValue.parameterPrompt {
                TextField(prompt, text: parameter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { commit() }
            }
            if let note = action.wrappedValue.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if action.wrappedValue.needsAccessibility && !Permissions.accessibilityGranted {
                Label("Needs Accessibility — grant it on the Setup tab",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    /// Wraps a binding so every write persists and reaches the engine. Doing
    /// it here rather than in `onChange` keeps the deployment target at 13.
    private func committing<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0; commit() })
    }

    private func commit() {
        let s = Settings.shared
        s.doubleAction = doubleAction
        s.leftAction = leftAction
        s.rightAction = rightAction
        s.customDouble = customDouble
        s.customLeft = customLeft
        s.customRight = customRight
        s.threshold = threshold
        s.doubleWindow = doubleWindow
        s.invertSides = invert
        s.inputGuard = inputGuard
        s.motionGuard = motionGuard
        s.playFeedback = feedback
        engine.applySettings()
    }
}

// MARK: - Pieces

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let ok: Bool
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(ok ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: ok ? "checkmark" : "\(number).circle.fill")
                    .font(.system(size: ok ? 12 : 16, weight: .bold))
                    .foregroundStyle(ok ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                content
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Hosting

final class SetupWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SetupView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "MagicTap"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

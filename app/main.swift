// MagicTap — menu bar app entry point.
//
// An accessory app: no Dock icon, no main window, lives in the status bar.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBar = controller

        // A blocked action opens setup rather than letting the system prompt
        // fire on every tap.
        TapEngine.shared.onPermissionNeeded = { [weak controller] in
            controller?.showSetup()
        }

        TapEngine.shared.start()

        // First launch, or a launch where the sensor is missing, opens setup so
        // the user is not left with a silent menu bar icon and no explanation.
        let firstRun = !Settings.shared.onboardingComplete
        var unsupported = false
        if case .unsupported = TapEngine.shared.status { unsupported = true }

        if firstRun || unsupported {
            controller.showSetup()
            Settings.shared.onboardingComplete = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

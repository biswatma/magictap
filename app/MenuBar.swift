// MenuBar — the status item next to the battery and Wi-Fi icons.

import AppKit
import Combine

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let setupWindow = SetupWindowController()
    private var cancellables = Set<AnyCancellable>()

    private let engine = TapEngine.shared

    override init() {
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "MagicTap"

        refreshIcon()

        // Keep the icon in step with enable/disable and sensor availability.
        engine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
    }

    func showSetup() {
        setupWindow.show()
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let active = Settings.shared.enabled && engine.status.isRunning
        let symbol = active ? "hand.tap.fill" : "hand.tap"
        let description = active ? "MagicTap active" : "MagicTap paused"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.appearsDisabled = !active
    }

    // MARK: - Menu

    /// Rebuilt on open so the state shown is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header(statusLine))

        if case .unsupported = engine.status {
            menu.addItem(header("This Mac has no motion sensor"))
        } else {
            let toggle = NSMenuItem(title: "Enabled",
                                    action: #selector(toggleEnabled),
                                    keyEquivalent: "")
            toggle.target = self
            toggle.state = Settings.shared.enabled ? .on : .off
            menu.addItem(toggle)
        }

        menu.addItem(.separator())

        if engine.blockedOnPermission && !Permissions.screenRecordingGranted {
            let warn = NSMenuItem(title: "⚠︎  Needs Screen Recording — open Setup",
                                  action: #selector(openSetup),
                                  keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        menu.addItem(header("Double tap  ›  \(Settings.shared.doubleAction.title)"))
        menu.addItem(header("Last  ›  \(engine.lastEvent)"))
        menu.addItem(header("\(engine.gestureCount) gestures this session"))
        if engine.suppressedCount > 0 {
            menu.addItem(header("\(engine.suppressedCount) taps ignored while typing"))
        }

        menu.addItem(.separator())

        let setup = NSMenuItem(title: "Setup & Permissions…",
                               action: #selector(openSetup),
                               keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)

        let calibrate = NSMenuItem(title: "Calibrate Left / Right…",
                                   action: #selector(openCalibration),
                                   keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)

        let log = NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MagicTap",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var statusLine: String {
        switch engine.status {
        case .unsupported: return "MagicTap — unsupported Mac"
        case .stopped: return "MagicTap — starting…"
        case .running: return Settings.shared.enabled ? "MagicTap — active" : "MagicTap — paused"
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        engine.setEnabled(!Settings.shared.enabled)
        refreshIcon()
    }

    @objc private func openSetup() {
        showSetup()
    }

    @objc private func openCalibration() {
        SetupNavigation.shared.tab = .calibrate
        showSetup()
    }

    @objc private func openLog() {
        Log.reveal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

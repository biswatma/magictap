// ActionExecutor — carries out an ActionID.
//
// Four mechanisms cover the catalogue:
//   * synthetic key events (CGEvent) for anything the system already binds
//   * NX system-defined events for the media and brightness keys, which are
//     not ordinary keystrokes
//   * the Accessibility API for moving and resizing another app's windows
//   * AppleScript, CoreWLAN, IOBluetooth and shell for the rest
//
// Everything in the first three groups needs Accessibility permission. Where a
// permission-free route exists — volume via AppleScript rather than the volume
// keys, lock screen via CGSession rather than ⌃⌘Q — it is preferred, so fewer
// actions are gated behind a prompt.

import Foundation
import AppKit
import CoreWLAN
import ApplicationServices

enum ActionExecutor {

    enum Failure: Error, CustomStringConvertible {
        case needsAccessibility
        case needsParameter(String)
        case noFrontWindow
        case script(String)
        case message(String)

        var description: String {
            switch self {
            case .needsAccessibility:  return "needs Accessibility permission"
            case .needsParameter(let p): return "needs a value: \(p)"
            case .noFrontWindow:       return "no focused window"
            case .script(let m):       return m
            case .message(let m):      return m
            }
        }
    }

    // MARK: - Entry point

    static func perform(_ action: ActionID, parameter: String) async throws {
        if action.needsAccessibility && !Permissions.accessibilityGranted {
            throw Failure.needsAccessibility
        }
        if let prompt = action.parameterPrompt,
           parameter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.needsParameter(prompt)
        }
        let value = parameter.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case .none: return

        // Screenshots & clipboard
        case .screenshotClipboard: try await Screenshot.toClipboard()
        case .screenshotDesktop:   _ = try await Screenshot.toDesktop()
        case .screenshotRegion:    try Screenshot.regionToClipboard()
        case .copy:       key(.c, [.maskCommand])
        case .paste:      key(.v, [.maskCommand])
        case .pastePlain: key(.v, [.maskCommand, .maskShift, .maskAlternate])
        case .undo:       key(.z, [.maskCommand])
        case .redo:       key(.z, [.maskCommand, .maskShift])

        // Media & volume — AppleScript avoids needing Accessibility.
        case .muteToggle:
            try script("set volume output muted (not (output muted of (get volume settings)))")
        case .volumeUp:   try nudgeVolume(+10)
        case .volumeDown: try nudgeVolume(-10)
        case .playPause:     media(NX.play)
        case .nextTrack:     media(NX.next)
        case .previousTrack: media(NX.previous)

        // Input, display & focus
        case .micToggle: try toggleMicrophone()
        case .brightnessUp:          media(NX.brightnessUp)
        case .brightnessDown:        media(NX.brightnessDown)
        case .keyboardBacklightUp:   media(NX.illuminationUp)
        case .keyboardBacklightDown: media(NX.illuminationDown)
        case .toggleFocus: try runShortcut(named: value)

        // Window & workspace
        case .missionControl: try open(app: "/System/Applications/Mission Control.app")
        case .spotlight:      key(.space, [.maskCommand])
        case .quickNote:      key(.q, [.maskSecondaryFn])
        case .minimizeWindow: key(.m, [.maskCommand])
        case .closeWindow:    key(.w, [.maskCommand])
        case .windowLeftHalf:   try place(.leftHalf)
        case .windowRightHalf:  try place(.rightHalf)
        case .maximizeWindow:   try place(.full)
        case .toggleFullScreen: key(.f, [.maskCommand, .maskControl])
        case .hideFrontApp:  key(.h, [.maskCommand])
        case .hideOtherApps: key(.h, [.maskCommand, .maskAlternate])
        case .previousSpace: key(.leftArrow, [.maskControl])
        case .nextSpace:     key(.rightArrow, [.maskControl])
        case .switchPreviousApp, .appSwitcher: key(.tab, [.maskCommand])
        case .quitFrontApp:  key(.q, [.maskCommand])

        // Lock, sleep & screensaver
        case .lockScreen:
            // CGSession needs no Accessibility, unlike synthesising ⌃⌘Q.
            try shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
                      ["-suspend"])
        case .screenSaver:
            try open(app: "/System/Library/CoreServices/ScreenSaverEngine.app")
        case .sleepDisplay:
            try shell("/usr/bin/pmset", ["displaysleepnow"])

        // Connectivity
        case .wifiToggle:      try toggleWiFi()
        case .bluetoothToggle: try toggleBluetooth()
        case .ejectDisks:      try ejectExternalDisks()

        // System status & utilities
        case .emptyTrash:
            try script("tell application \"Finder\" to empty the trash")
        case .batteryStatus:  try showBatteryStatus()
        case .newEmail:       NSWorkspace.shared.open(URL(string: "mailto:")!)
        case .currentWeather: try open(app: "/System/Applications/Weather.app")

        // Custom
        case .pressShortcut:
            guard let combo = KeyCombo(parsing: value) else {
                throw Failure.message("could not parse shortcut “\(value)”")
            }
            key(combo.code, combo.flags)
        case .openApp:
            guard NSWorkspace.shared.launchApplication(value) else {
                throw Failure.message("could not open “\(value)”")
            }
        case .openURL:
            let text = value.contains("://") ? value : "https://\(value)"
            guard let url = URL(string: text) else {
                throw Failure.message("not a valid URL: \(value)")
            }
            NSWorkspace.shared.open(url)
        case .runShortcut:   try runShortcut(named: value)
        case .customCommand: try shell("/bin/sh", ["-c", value])
        }
    }

    // MARK: - Key synthesis

    /// Virtual key codes, from Carbon's Events.h.
    enum Key: CGKeyCode {
        case c = 8, v = 9, z = 6, q = 12, w = 13, m = 46, h = 4, f = 3
        case tab = 48, space = 49
        case leftArrow = 123, rightArrow = 124
    }

    static func key(_ k: Key, _ flags: CGEventFlags) {
        key(k.rawValue, flags)
    }

    static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// NX_KEYTYPE_* codes for the special keys, which are delivered as
    /// system-defined events rather than keystrokes.
    enum NX {
        static let soundUp: Int32 = 0, soundDown: Int32 = 1
        static let brightnessUp: Int32 = 2, brightnessDown: Int32 = 3
        static let mute: Int32 = 7
        static let play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18
        static let illuminationUp: Int32 = 21, illuminationDown: Int32 = 22
    }

    static func media(_ nxKey: Int32) {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0x0A : 0x0B
            let data1 = Int((nxKey << 16) | (state << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(isDown ? 0xA00 : 0xB00)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Windows

    enum Placement { case leftHalf, rightHalf, full }

    private static func place(_ placement: Placement) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw Failure.noFrontWindow }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let window = windowRef else { throw Failure.noFrontWindow }
        let axWindow = window as! AXUIElement

        guard let screen = NSScreen.main else { throw Failure.noFrontWindow }
        let visible = screen.visibleFrame

        var target = visible
        switch placement {
        case .leftHalf:  target.size.width /= 2
        case .rightHalf: target.size.width /= 2; target.origin.x += target.size.width
        case .full:      break
        }

        // Accessibility uses a top-left origin with y increasing downward;
        // NSScreen uses bottom-left. Flip against the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        var origin = CGPoint(x: target.origin.x,
                             y: primaryHeight - target.origin.y - target.size.height)
        var size = CGSize(width: target.size.width, height: target.size.height)

        guard let originValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw Failure.message("could not build window geometry")
        }
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
    }

    // MARK: - System helpers

    private static func nudgeVolume(_ delta: Int) throws {
        try script("""
            set current to output volume of (get volume settings)
            set target to current + (\(delta))
            if target > 100 then set target to 100
            if target < 0 then set target to 0
            set volume output volume target
            set volume without output muted
            """)
    }

    private static func toggleMicrophone() throws {
        let defaults = UserDefaults.standard
        let key = "micVolumeBeforeMute"
        let current = try scriptResult("input volume of (get volume settings)")
        let level = Int(current) ?? 0
        if level > 0 {
            defaults.set(level, forKey: key)
            try script("set volume input volume 0")
        } else {
            let restore = max(defaults.integer(forKey: key), 50)
            try script("set volume input volume \(restore)")
        }
    }

    private static func toggleWiFi() throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw Failure.message("no Wi-Fi interface")
        }
        try interface.setPower(!interface.powerOn())
    }

    /// IOBluetooth's power control is private, so it is resolved at runtime.
    private static func toggleBluetooth() throws {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOBluetooth.framework/Versions/A/IOBluetooth", RTLD_LAZY),
            let getSym = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
            let setSym = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
        else { throw Failure.message("Bluetooth control unavailable on this macOS") }

        typealias Get = @convention(c) () -> Int32
        typealias Set = @convention(c) (Int32) -> Void
        let get = unsafeBitCast(getSym, to: Get.self)
        let set = unsafeBitCast(setSym, to: Set.self)
        set(get() != 0 ? 0 : 1)
    }

    /// Uses the volume list rather than Finder, so no Automation prompt.
    private static func ejectExternalDisks() throws {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var ejected = 0
        for url in volumes {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let ejectable = (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false)
            let internalDisk = values?.volumeIsInternal ?? true
            guard ejectable, !internalDisk else { continue }
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            ejected += 1
        }
        if ejected == 0 { throw Failure.message("no external disks mounted") }
        try notify("Ejected \(ejected) disk\(ejected == 1 ? "" : "s")")
    }

    private static func showBatteryStatus() throws {
        let output = try shellOutput("/usr/bin/pmset", ["-g", "batt"])
        // e.g. "-InternalBattery-0 (id=…)\t82%; discharging; 4:11 remaining present: true"
        var message = output
        if let line = output.split(separator: "\n").last {
            let parts = line.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let percent = parts.first?.components(separatedBy: "\t").last ?? ""
            let state = parts.count > 1 ? parts[1] : ""
            let remaining = parts.count > 2
                ? parts[2].replacingOccurrences(of: " present: true", with: "") : ""
            message = [percent, state, remaining]
                .filter { !$0.isEmpty && $0 != "(no estimate)" }
                .joined(separator: " · ")
        }
        try notify(message.isEmpty ? "Battery status unavailable" : message)
    }

    private static func runShortcut(named name: String) throws {
        try shell("/usr/bin/shortcuts", ["run", name])
    }

    // MARK: - Plumbing

    private static func open(app path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure.message("not present on this Mac: \(url.lastPathComponent)")
        }
        NSWorkspace.shared.open(url)
    }

    private static func notify(_ message: String) throws {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        try script("display notification \"\(escaped)\" with title \"MagicTap\"")
    }

    @discardableResult
    private static func script(_ source: String) throws -> String {
        try scriptResult(source)
    }

    @discardableResult
    private static func scriptResult(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw Failure.script(error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed")
        }
        return result?.stringValue ?? ""
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
    }

    private static func shellOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Shortcut parsing

/// Parses text like "cmd+shift+4" or "ctrl+opt+space" into a key event.
struct KeyCombo {
    let code: CGKeyCode
    let flags: CGEventFlags

    private static let names: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    init?(parsing text: String) {
        let parts = text.lowercased()
            .split(whereSeparator: { "+- ".contains($0) })
            .map(String.init)
        guard !parts.isEmpty else { return nil }

        var flags = CGEventFlags()
        var code: CGKeyCode?
        for part in parts {
            if let modifier = Self.modifiers[part] {
                flags.insert(modifier)
            } else if let key = Self.names[part] {
                code = key
            } else {
                return nil
            }
        }
        guard let code else { return nil }
        self.code = code
        self.flags = flags
    }
}

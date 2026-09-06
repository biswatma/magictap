// Actions — the catalogue of things a gesture can trigger.
//
// Each case carries its own title, group, parameter prompt and permission
// requirements, so the settings UI and the permission checks are both derived
// from this one list rather than kept in sync by hand.

import Foundation

enum ActionGroup: String, CaseIterable, Identifiable {
    case none = "None"
    case screenshots = "Screenshots & clipboard"
    case media = "Media & volume"
    case display = "Input, display & focus"
    case window = "Window & workspace"
    case lock = "Lock, sleep & screensaver"
    case connectivity = "Connectivity"
    case system = "System status & utilities"
    case custom = "Custom shortcuts"

    var id: String { rawValue }

    var actions: [ActionID] { ActionID.allCases.filter { $0.group == self } }
}

enum ActionID: String, CaseIterable, Identifiable {
    case none

    // Screenshots & clipboard
    case screenshotClipboard, screenshotDesktop, screenshotRegion
    case copy, paste, pastePlain, undo, redo

    // Media & volume
    case muteToggle, volumeUp, volumeDown, playPause, nextTrack, previousTrack

    // Input, display & focus
    case micToggle, brightnessUp, brightnessDown
    case keyboardBacklightUp, keyboardBacklightDown, toggleFocus

    // Window & workspace
    case missionControl, spotlight, quickNote
    case minimizeWindow, closeWindow
    case windowLeftHalf, windowRightHalf, maximizeWindow, toggleFullScreen
    case hideFrontApp, hideOtherApps
    case previousSpace, nextSpace, switchPreviousApp, appSwitcher, quitFrontApp

    // Lock, sleep & screensaver
    case lockScreen, screenSaver, sleepDisplay

    // Connectivity
    case wifiToggle, bluetoothToggle, ejectDisks

    // System status & utilities
    case emptyTrash, batteryStatus, newEmail, currentWeather

    // Custom
    case pressShortcut, openApp, openURL, runShortcut, customCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Do nothing"

        case .screenshotClipboard: return "Screenshot → Clipboard"
        case .screenshotDesktop:   return "Screenshot → Desktop"
        case .screenshotRegion:    return "Screenshot (select area)"
        case .copy:       return "Copy (⌘C)"
        case .paste:      return "Paste (⌘V)"
        case .pastePlain: return "Paste without formatting"
        case .undo:       return "Undo (⌘Z)"
        case .redo:       return "Redo (⇧⌘Z)"

        case .muteToggle:    return "Mute / unmute sound"
        case .volumeUp:      return "Volume up"
        case .volumeDown:    return "Volume down"
        case .playPause:     return "Play / Pause"
        case .nextTrack:     return "Next track"
        case .previousTrack: return "Previous track"

        case .micToggle:             return "Mute / unmute microphone"
        case .brightnessUp:          return "Brightness up"
        case .brightnessDown:        return "Brightness down"
        case .keyboardBacklightUp:   return "Keyboard backlight up"
        case .keyboardBacklightDown: return "Keyboard backlight down"
        case .toggleFocus:           return "Toggle Focus…"

        case .missionControl:    return "Mission Control"
        case .spotlight:         return "Spotlight search"
        case .quickNote:         return "Quick Note"
        case .minimizeWindow:    return "Minimize front window"
        case .closeWindow:       return "Close front window"
        case .windowLeftHalf:    return "Window → left half"
        case .windowRightHalf:   return "Window → right half"
        case .maximizeWindow:    return "Maximize window"
        case .toggleFullScreen:  return "Toggle full screen"
        case .hideFrontApp:      return "Hide front app"
        case .hideOtherApps:     return "Hide other apps"
        case .previousSpace:     return "Previous Space"
        case .nextSpace:         return "Next Space"
        case .switchPreviousApp: return "Switch to previous app"
        case .appSwitcher:       return "App switcher (tap to step)"
        case .quitFrontApp:      return "Quit front app"

        case .lockScreen:  return "Lock screen"
        case .screenSaver: return "Start screen saver"
        case .sleepDisplay: return "Sleep display"

        case .wifiToggle:      return "Wi-Fi on / off"
        case .bluetoothToggle: return "Bluetooth on / off"
        case .ejectDisks:      return "Eject external disks"

        case .emptyTrash:     return "Empty Trash"
        case .batteryStatus:  return "Battery status"
        case .newEmail:       return "New email"
        case .currentWeather: return "Current weather"

        case .pressShortcut:  return "Press keyboard shortcut…"
        case .openApp:        return "Open application…"
        case .openURL:        return "Open URL…"
        case .runShortcut:    return "Run Shortcut…"
        case .customCommand:  return "Run a custom command…"
        }
    }

    var group: ActionGroup {
        switch self {
        case .none: return .none
        case .screenshotClipboard, .screenshotDesktop, .screenshotRegion,
             .copy, .paste, .pastePlain, .undo, .redo:
            return .screenshots
        case .muteToggle, .volumeUp, .volumeDown, .playPause, .nextTrack, .previousTrack:
            return .media
        case .micToggle, .brightnessUp, .brightnessDown,
             .keyboardBacklightUp, .keyboardBacklightDown, .toggleFocus:
            return .display
        case .missionControl, .spotlight, .quickNote, .minimizeWindow, .closeWindow,
             .windowLeftHalf, .windowRightHalf, .maximizeWindow, .toggleFullScreen,
             .hideFrontApp, .hideOtherApps, .previousSpace, .nextSpace,
             .switchPreviousApp, .appSwitcher, .quitFrontApp:
            return .window
        case .lockScreen, .screenSaver, .sleepDisplay:
            return .lock
        case .wifiToggle, .bluetoothToggle, .ejectDisks:
            return .connectivity
        case .emptyTrash, .batteryStatus, .newEmail, .currentWeather:
            return .system
        case .pressShortcut, .openApp, .openURL, .runShortcut, .customCommand:
            return .custom
        }
    }

    /// Capturing the screen.
    var needsScreenRecording: Bool {
        switch self {
        case .screenshotClipboard, .screenshotDesktop, .screenshotRegion: return true
        default: return false
        }
    }

    /// Synthesising keystrokes or repositioning another app's windows. macOS
    /// gates both behind Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .copy, .paste, .pastePlain, .undo, .redo,
             .brightnessUp, .brightnessDown,
             .keyboardBacklightUp, .keyboardBacklightDown,
             .playPause, .nextTrack, .previousTrack,
             .spotlight, .quickNote, .minimizeWindow, .closeWindow,
             .windowLeftHalf, .windowRightHalf, .maximizeWindow, .toggleFullScreen,
             .hideFrontApp, .hideOtherApps, .previousSpace, .nextSpace,
             .switchPreviousApp, .appSwitcher, .quitFrontApp,
             .pressShortcut:
            return true
        default:
            return false
        }
    }

    /// Non-nil when the action needs a value from the user.
    var parameterPrompt: String? {
        switch self {
        case .pressShortcut: return "Shortcut, e.g. cmd+shift+4"
        case .openApp:       return "Application name, e.g. Safari"
        case .openURL:       return "URL, e.g. https://example.com"
        case .runShortcut:   return "Shortcut name, from the Shortcuts app"
        case .customCommand: return "Shell command"
        case .toggleFocus:   return "Name of a Shortcut that toggles the Focus"
        default:             return nil
        }
    }

    /// Shown under the picker when the behaviour needs explaining.
    var note: String? {
        switch self {
        case .toggleFocus:
            return """
                macOS exposes no public API for Focus modes. Create a Shortcut \
                that sets the Focus you want and name it here.
                """
        case .appSwitcher:
            return "Sends ⌘Tab. Stepping further needs the key held, which a tap cannot do."
        case .currentWeather:
            return "Opens the Weather app."
        case .emptyTrash, .ejectDisks:
            return "Asks for permission to control Finder the first time."
        default:
            return nil
        }
    }
}

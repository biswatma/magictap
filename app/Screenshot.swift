// Screenshot — captures in-process via ScreenCaptureKit.
//
// The first version shelled out to /usr/sbin/screencapture. That re-triggered
// the Screen Recording prompt on *every* capture: TCC attributes a spawned
// binary's request to that binary, not reliably to the app that launched it, so
// the grant never stuck and each tap raised the dialog again.
//
// Capturing in-process makes the permission unambiguously MagicTap's own, so it
// is asked for once and then remembered. Interactive region select still needs
// the subprocess, because that UI belongs to the system tool.

import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

enum Screenshot {
    enum Failure: Error, CustomStringConvertible {
        case noPermission
        case noDisplay
        case encodingFailed
        case underlying(String)

        var description: String {
            switch self {
            case .noPermission:   return "Screen Recording permission not granted"
            case .noDisplay:      return "no display found to capture"
            case .encodingFailed: return "could not encode the captured image"
            case .underlying(let m): return m
            }
        }
    }

    /// The display under the pointer, so the right screen is grabbed on a
    /// multi-monitor setup.
    private static func activeDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let match = displays.first(where: { $0.displayID == number }) {
            return match
        }
        return displays.first
    }

    private static func capture() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(from: content.displays) else {
            throw Failure.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Match the backing scale so a Retina capture is not downsampled.
        let scale = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure.encodingFailed
        }
        return data
    }

    /// Whole screen to the clipboard.
    static func toClipboard() async throws {
        let image = try await capture()
        let data = try pngData(image)
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
        // Also offer TIFF, which some older apps paste in preference to PNG.
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            board.setData(tiff, forType: .tiff)
        }
    }

    /// Whole screen to a timestamped file on the Desktop. Returns its URL.
    @discardableResult
    static func toDesktop() async throws -> URL {
        let image = try await capture()
        let data = try pngData(image)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "MagicTap \(formatter.string(from: Date())).png"

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Interactive region select. This one keeps the subprocess: the crosshair
    /// UI is the system tool's, and there is no in-process equivalent.
    static func regionToClipboard() throws {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.noPermission }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-c", "-i", "-x"]
        try process.run()
    }
}

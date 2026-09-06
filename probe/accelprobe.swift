// accelprobe — dump raw HID reports from the Apple SPU motion sensors.
//
// The accelerometer and gyroscope on Apple silicon MacBooks (2021 redesign
// onward) sit behind the Sensor Processing Unit as vendor-defined HID devices:
//
//   accel  vendor 0x05AC  usage page 0xFF00  usage 3
//   gyro   vendor 0x05AC  usage page 0xFF00  usage 9
//
// The usage page is vendor-defined, so the report layout is undocumented.
// This tool prints each report as hex plus a signed 16-bit LE decode; tilt the
// machine and watch which lanes track gravity to infer the axis layout.

import Foundation
import IOKit
import IOKit.hid

let kVendorApple = 0x05AC
let kUsagePageSPU = 0xFF00
let kUsageAccel = 3
let kUsageGyro = 9

// MARK: - Options

struct Options {
    var usage = kUsageAccel
    var label = "accel"
    var fullRate = false
    var limit = Int.max
    var hex = true
}

func parseArgs() -> Options {
    var o = Options()
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "--gyro":
            o.usage = kUsageGyro
            o.label = "gyro"
        case "--accel":
            o.usage = kUsageAccel
            o.label = "accel"
        case "--full":
            o.fullRate = true
        case "--no-hex":
            o.hex = false
        case "-h", "--help":
            print("""
            accelprobe — stream raw reports from the SPU motion sensors

              --accel     accelerometer, usage 3 (default)
              --gyro      gyroscope, usage 9
              --full      print every report (125 Hz) instead of ~10 Hz
              --no-hex    omit the hex dump, show decoded int16 lanes only
              --n=N       stop after N reports
            """)
            exit(0)
        default:
            if arg.hasPrefix("--n=") {
                o.limit = Int(arg.dropFirst(4)) ?? Int.max
            } else {
                FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!)
                exit(2)
            }
        }
    }
    return o
}

let opts = parseArgs()

// Line-buffered so output survives redirection and mid-stream termination.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Per-device state

final class DeviceContext {
    let device: IOHIDDevice
    let label: String
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferLength: Int
    var received = 0
    var lastPrinted = Date.distantPast

    init(device: IOHIDDevice, label: String, bufferLength: Int) {
        self.device = device
        self.label = label
        self.bufferLength = bufferLength
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        self.buffer.initialize(repeating: 0, count: bufferLength)
    }

    func handle(report: UnsafeMutablePointer<UInt8>, length: CFIndex, reportID: UInt32) {
        received += 1

        if !opts.fullRate {
            let now = Date()
            guard now.timeIntervalSince(lastPrinted) >= 0.1 else { return }
            lastPrinted = now
        }

        let bytes = UnsafeBufferPointer(start: report, count: max(0, Int(length)))

        var line = String(format: "[%@] #%06d id=%d len=%2d", label, received, reportID, bytes.count)

        if opts.hex {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            line += " | \(hex)"
        }

        // Signed 16-bit little-endian lanes. Whichever three track gravity as
        // you tilt the machine are the accelerometer axes.
        var lanes: [String] = []
        var i = 0
        while i + 1 < bytes.count {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            lanes.append(String(format: "%7d", Int16(bitPattern: raw)))
            i += 2
        }
        if !lanes.isEmpty {
            line += " | i16:" + lanes.joined(separator: " ")
        }

        print(line)
        fflush(stdout)

        if received >= opts.limit {
            print("\nreached --n limit (\(opts.limit)), exiting")
            exit(0)
        }
    }

    deinit {
        buffer.deinitialize(count: bufferLength)
        buffer.deallocate()
    }
}

// Retained for the lifetime of the process; the C callback reaches them through
// an opaque context pointer, so they must not be deallocated.
var contexts: [DeviceContext] = []

let onReport: IOHIDReportCallback = { context, _, _, _, reportID, report, reportLength in
    guard let context else { return }
    let ctx = Unmanaged<DeviceContext>.fromOpaque(context).takeUnretainedValue()
    ctx.handle(report: report, length: reportLength, reportID: reportID)
}

// MARK: - Element dump

func describeElements(_ device: IOHIDDevice) {
    guard let raw = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement],
          !raw.isEmpty else {
        print("  (no HID elements reported)")
        return
    }
    print("  elements (\(raw.count)):")
    for e in raw {
        let page = IOHIDElementGetUsagePage(e)
        let usage = IOHIDElementGetUsage(e)
        let size = IOHIDElementGetReportSize(e)
        let count = IOHIDElementGetReportCount(e)
        let reportID = IOHIDElementGetReportID(e)
        let lmin = IOHIDElementGetLogicalMin(e)
        let lmax = IOHIDElementGetLogicalMax(e)
        print(String(format: "    page=0x%04x usage=0x%02x reportID=%d size=%dx%d logical=[%ld,%ld]",
                     page, usage, reportID, count, size, lmin, lmax))
    }
}

// MARK: - Main

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDVendorIDKey: kVendorApple,
    kIOHIDPrimaryUsagePageKey: kUsagePageSPU,
    kIOHIDPrimaryUsageKey: opts.usage,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    FileHandle.standardError.write(
        String(format: "IOHIDManagerOpen failed: 0x%08x\n", openResult).data(using: .utf8)!)
    FileHandle.standardError.write(
        "If this is a permissions error, grant Input Monitoring to the terminal.\n".data(using: .utf8)!)
    exit(1)
}

guard let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !found.isEmpty else {
    FileHandle.standardError.write(
        "No matching device (vendor 0x05AC, page 0xFF00, usage \(opts.usage)).\n".data(using: .utf8)!)
    FileHandle.standardError.write(
        "This Mac may predate the SPU IMU. Check: ioreg -w0 | grep -E 'accel|gyro'\n".data(using: .utf8)!)
    exit(1)
}

print("matched \(found.count) device(s) for usage \(opts.usage) (\(opts.label))\n")

for device in found {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "(unnamed)"
    let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
    let interval = IOHIDDeviceGetProperty(device, kIOHIDReportIntervalKey as CFString) as? Int ?? 0

    print("device: \(product)")
    print("  maxInputReportSize=\(maxReport) reportInterval=\(interval)us"
          + (interval > 0 ? String(format: " (%.1f Hz)", 1_000_000.0 / Double(interval)) : ""))
    describeElements(device)
    print("")

    if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
        FileHandle.standardError.write("  warning: IOHIDDeviceOpen failed, skipping\n".data(using: .utf8)!)
        continue
    }

    let ctx = DeviceContext(device: device, label: opts.label, bufferLength: max(maxReport, 8))
    contexts.append(ctx)

    IOHIDDeviceRegisterInputReportCallback(
        device,
        ctx.buffer,
        ctx.bufferLength,
        onReport,
        Unmanaged.passUnretained(ctx).toOpaque())

    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

if contexts.isEmpty {
    FileHandle.standardError.write("could not open any matching device\n".data(using: .utf8)!)
    exit(1)
}

print("streaming — tilt the machine, then tap the left and right palm rests. Ctrl-C to stop.\n")
CFRunLoopRun()

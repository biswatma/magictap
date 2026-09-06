// HIDMotion — access to the SPU motion sensors on Apple silicon MacBooks.
//
// These MacBooks carry a Bosch BMI282 6-axis IMU behind the Sensor Processing
// Unit, exposed as vendor-defined HID devices (page 0xFF00, usage 3 = accel,
// usage 9 = gyro). The driver is marked motionRestrictedService, so neither
// IOHIDDevice input reports nor IOHIDServiceClientCopyEvent deliver anything.
// Registering a push callback on the HID *event system* does work, and that is
// what this file wraps.
//
// The event-system symbols are private, so they are resolved with dlsym rather
// than linked against. If a future macOS removes them, `MotionSource.start`
// reports the failure instead of crashing.

import Foundation
import IOKit

// MARK: - Private symbol bindings

private let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY)

private func sym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let iokit, let p = dlsym(iokit, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private typealias FnClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
private typealias FnSetMatching = @convention(c) (CFTypeRef?, CFDictionary?) -> Void
private typealias FnCopyServices = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
private typealias FnGetFloat = @convention(c) (CFTypeRef?, Int32) -> Double
private typealias FnGetType = @convention(c) (CFTypeRef?) -> Int64
private typealias FnCopyProp = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
private typealias FnSetProp = @convention(c) (CFTypeRef?, CFString?, CFTypeRef?) -> Bool
typealias HIDEventCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, CFTypeRef?) -> Void
private typealias FnRegisterCallback = @convention(c) (
    CFTypeRef?, HIDEventCallback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias FnScheduleRunLoop = @convention(c) (CFTypeRef?, CFRunLoop?, CFString?) -> Void

private let clientCreate = sym("IOHIDEventSystemClientCreate", FnClientCreate.self)
private let setMatching = sym("IOHIDEventSystemClientSetMatching", FnSetMatching.self)
private let copyServices = sym("IOHIDEventSystemClientCopyServices", FnCopyServices.self)
private let getFloat = sym("IOHIDEventGetFloatValue", FnGetFloat.self)
private let getType = sym("IOHIDEventGetType", FnGetType.self)
private let copyProp = sym("IOHIDServiceClientCopyProperty", FnCopyProp.self)
private let setProp = sym("IOHIDServiceClientSetProperty", FnSetProp.self)
private let registerCallback = sym("IOHIDEventSystemClientRegisterEventCallback", FnRegisterCallback.self)
private let scheduleRunLoop = sym("IOHIDEventSystemClientScheduleWithRunLoop", FnScheduleRunLoop.self)

// MARK: - Public surface

/// IOHIDEventTypes.h. A field id is `(type << 16) + axisIndex`.
public enum MotionKind: Int64 {
    case accelerometer = 13
    case gyro = 20

    var usage: Int { self == .accelerometer ? 3 : 9 }
    var name: String { self == .accelerometer ? "accel" : "gyro" }
    func field(_ axis: Int32) -> Int32 { Int32(rawValue << 16) + axis }
}

public struct MotionSample {
    public let x, y, z: Double
    public let time: CFAbsoluteTime

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

public enum MotionError: Error, CustomStringConvertible {
    case symbolsUnavailable
    case clientCreateFailed
    case noMatchingService(MotionKind)

    public var description: String {
        switch self {
        case .symbolsUnavailable:
            return "IOHIDEventSystemClient symbols are unavailable on this macOS build"
        case .clientCreateFailed:
            return "IOHIDEventSystemClientCreate returned null"
        case .noMatchingService(let kind):
            return """
                no \(kind.name) service (vendor page 0xFF00, usage \(kind.usage)).
                This Mac probably predates the SPU IMU — it arrived with the 2021 \
                MacBook Pro and 2022 MacBook Air redesigns.
                """
        }
    }
}

/// A single live source; the C event callback cannot carry context, so the
/// active instance is reachable through a file-global.
private var activeSource: MotionSource?

private let onHIDEvent: HIDEventCallback = { _, _, _, event in
    guard let event,
          let source = activeSource,
          let getType, let getFloat else { return }
    let type = getType(event)
    guard type == source.kind.rawValue else { return }
    source.deliver(MotionSample(
        x: getFloat(event, source.kind.field(0)),
        y: getFloat(event, source.kind.field(1)),
        z: getFloat(event, source.kind.field(2)),
        time: CFAbsoluteTimeGetCurrent()))
}

public final class MotionSource {
    public let kind: MotionKind
    private var client: CFTypeRef?
    private var services: [CFTypeRef] = []
    private var handler: ((MotionSample) -> Void)?

    public init(kind: MotionKind) {
        self.kind = kind
    }

    /// Properties of the matched service, for diagnostics.
    public func describeService() -> [String: String] {
        guard let svc = services.first else { return [:] }
        var out: [String: String] = [:]
        for key in ["model", "manufacturer", "sensor_rates", "ReportInterval",
                    "PrimaryUsage", "PrimaryUsagePage", "motionRestrictedService"] {
            if let v = copyProp?(svc, key as CFString)?.takeRetainedValue() {
                out[key] = String(describing: v).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// Ask the driver for a report interval in microseconds. The BMI282
    /// advertises 50/100/200/400/800 Hz; 1250us requests the top rate.
    @discardableResult
    public func requestInterval(microseconds: Int) -> Bool {
        var ok = false
        for svc in services {
            ok = (setProp?(svc, "ReportInterval" as CFString, microseconds as CFNumber) ?? false) || ok
        }
        return ok
    }

    public func connect() throws {
        guard clientCreate != nil, copyServices != nil, getFloat != nil, getType != nil,
              registerCallback != nil, scheduleRunLoop != nil else {
            throw MotionError.symbolsUnavailable
        }
        guard let c = clientCreate?(kCFAllocatorDefault)?.takeRetainedValue() else {
            throw MotionError.clientCreateFailed
        }
        client = c

        let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": kind.usage]
        setMatching?(c, matching as CFDictionary)

        guard let found = copyServices?(c)?.takeRetainedValue() as? [CFTypeRef], !found.isEmpty else {
            throw MotionError.noMatchingService(kind)
        }
        services = found
    }

    /// Begins delivering samples on the current run loop. Call `CFRunLoopRun()`
    /// (or run an NSApplication) afterwards.
    public func start(_ handler: @escaping (MotionSample) -> Void) {
        self.handler = handler
        activeSource = self
        registerCallback?(client, onHIDEvent, nil, nil)
        scheduleRunLoop?(client, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    fileprivate func deliver(_ sample: MotionSample) {
        handler?(sample)
    }
}

/// Sliding-window sample-rate estimate. A plain since-start average is
/// misleading here: the event system delivers the first samples as a burst.
public struct RateMeter {
    private var times: [CFAbsoluteTime] = []
    private let window: Double

    public init(window: Double = 1.0) {
        self.window = window
    }

    public mutating func tick(_ t: CFAbsoluteTime) -> Double {
        times.append(t)
        let cutoff = t - window
        if let keep = times.firstIndex(where: { $0 >= cutoff }), keep > 0 {
            times.removeFirst(keep)
        }
        guard times.count > 1, let first = times.first else { return 0 }
        let span = t - first
        return span > 0 ? Double(times.count - 1) / span : 0
    }
}

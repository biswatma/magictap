// sensorprobe — read the SPU accelerometer/gyro via IOHIDEventSystemClient.
//
// The AppleSPUHIDDriver for these sensors is marked "motionRestrictedService",
// so opening the IOHIDDevice and waiting for input reports yields nothing (see
// accelprobe.swift). The HID *event system* exposes the same sensors as typed
// events instead, which is the path that actually delivers data.
//
// These symbols are private, so they are resolved at runtime via dlsym rather
// than linked against.

import Foundation
import IOKit

// MARK: - Private IOHIDEventSystem bindings

typealias EventSystemClient = CFTypeRef
typealias ServiceClient = CFTypeRef
typealias HIDEvent = CFTypeRef

// IOHIDEventTypes.h — field for an event type is (type << 16) + axis index.
let kEventTypeAccelerometer: Int64 = 13
let kEventTypeGyro: Int64 = 20

func field(_ type: Int64, _ index: Int32) -> Int32 { Int32(type << 16) + index }

private let iokit: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY)

private func sym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let iokit, let p = dlsym(iokit, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias FnClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
typealias FnSetMatching = @convention(c) (CFTypeRef?, CFDictionary?) -> Void
typealias FnCopyServices = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
typealias FnCopyEvent = @convention(c) (CFTypeRef?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
typealias FnGetFloat = @convention(c) (CFTypeRef?, Int32) -> Double
typealias FnGetType = @convention(c) (CFTypeRef?) -> Int64
typealias FnServiceCopyProp = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
typealias FnServiceSetProp = @convention(c) (CFTypeRef?, CFString?, CFTypeRef?) -> Bool
typealias FnEventCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, CFTypeRef?) -> Void
typealias FnRegisterCallback = @convention(c) (
    CFTypeRef?, FnEventCallback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
typealias FnScheduleRunLoop = @convention(c) (CFTypeRef?, CFRunLoop?, CFString?) -> Void

let clientCreate = sym("IOHIDEventSystemClientCreate", FnClientCreate.self)
let setMatching = sym("IOHIDEventSystemClientSetMatching", FnSetMatching.self)
let copyServices = sym("IOHIDEventSystemClientCopyServices", FnCopyServices.self)
let copyEvent = sym("IOHIDServiceClientCopyEvent", FnCopyEvent.self)
let getFloat = sym("IOHIDEventGetFloatValue", FnGetFloat.self)
let getType = sym("IOHIDEventGetType", FnGetType.self)
let serviceCopyProp = sym("IOHIDServiceClientCopyProperty", FnServiceCopyProp.self)
let serviceSetProp = sym("IOHIDServiceClientSetProperty", FnServiceSetProp.self)
let registerCallback = sym("IOHIDEventSystemClientRegisterEventCallback", FnRegisterCallback.self)
let scheduleRunLoop = sym("IOHIDEventSystemClientScheduleWithRunLoop", FnScheduleRunLoop.self)

// MARK: - Options

var wantGyro = false
var pollHz = 0.0          // 0 = use push callbacks
var limit = Int.max
var listOnly = false

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--gyro": wantGyro = true
    case "--list": listOnly = true
    case "-h", "--help":
        print("""
        sensorprobe — read SPU motion sensors via the HID event system

          --list       enumerate matching services and their properties, then exit
          --gyro       read the gyroscope instead of the accelerometer
          --poll=HZ    poll at HZ instead of using push callbacks
          --n=N        stop after N samples
        """)
        exit(0)
    default:
        if arg.hasPrefix("--poll=") { pollHz = Double(arg.dropFirst(7)) ?? 100 }
        else if arg.hasPrefix("--n=") { limit = Int(arg.dropFirst(4)) ?? Int.max }
        else { FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!); exit(2) }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

let eventType = wantGyro ? kEventTypeGyro : kEventTypeAccelerometer
let label = wantGyro ? "gyro" : "accel"

// MARK: - Bring up the client

guard let clientCreate, let copyServices, let copyEvent, let getFloat else {
    FileHandle.standardError.write("failed to resolve IOHIDEventSystemClient symbols\n".data(using: .utf8)!)
    exit(1)
}

guard let client = clientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
    FileHandle.standardError.write("IOHIDEventSystemClientCreate returned null\n".data(using: .utf8)!)
    exit(1)
}

// Vendor page 0xFF00, usage 3 = accel, usage 9 = gyro.
let matching: [String: Any] = [
    "PrimaryUsagePage": 0xFF00,
    "PrimaryUsage": wantGyro ? 9 : 3,
]
setMatching?(client, matching as CFDictionary)

guard let services = copyServices(client)?.takeRetainedValue() as? [ServiceClient], !services.isEmpty else {
    FileHandle.standardError.write("no matching HID services for \(label)\n".data(using: .utf8)!)
    exit(1)
}

print("matched \(services.count) service(s) for \(label)\n")

for (i, svc) in services.enumerated() {
    print("service[\(i)]:")
    for key in ["Product", "model", "manufacturer", "sensor_rates", "ReportInterval",
                "PrimaryUsage", "PrimaryUsagePage", "motionRestrictedService"] {
        if let v = serviceCopyProp?(svc, key as CFString)?.takeRetainedValue() {
            print("  \(key) = \(v)")
        }
    }
}
print("")

if listOnly { exit(0) }

// Ask for the fastest rate the driver advertises (BMI282 tops out at 800 Hz).
// ReportInterval is in microseconds; 1250us = 800 Hz.
for svc in services {
    let ok = serviceSetProp?(svc, "ReportInterval" as CFString, 1250 as CFNumber) ?? false
    print("set ReportInterval=1250us (800 Hz): \(ok ? "accepted" : "rejected")")
}
print("")

// MARK: - Sampling

final class Sampler {
    let label: String
    let limit: Int
    var count = 0
    var first: Date?

    init(label: String, limit: Int) {
        self.label = label
        self.limit = limit
    }

    func emit(_ x: Double, _ y: Double, _ z: Double) {
        if first == nil { first = Date() }
        count += 1
        let mag = (x * x + y * y + z * z).squareRoot()
        let hz = count > 1 ? Double(count) / max(Date().timeIntervalSince(first!), 1e-9) : 0
        print(String(format: "[%@] #%06d  x=%+9.5f  y=%+9.5f  z=%+9.5f  |v|=%8.5f  %6.1f Hz",
                     label, count, x, y, z, mag, hz))
        if count >= limit {
            print("\nreached --n limit (\(limit)), exiting")
            exit(0)
        }
    }
}

// A @convention(c) callback cannot capture context, and top-level bindings in a
// script count as captures — so everything the callback touches lives here.
enum Shared {
    static var eventType: Int64 = kEventTypeAccelerometer
    static var sampler: Sampler?
    static var getFloatFn: FnGetFloat?
    static var getTypeFn: FnGetType?
}

let sampler = Sampler(label: label, limit: limit)
Shared.eventType = eventType
Shared.sampler = sampler
Shared.getFloatFn = getFloat
Shared.getTypeFn = getType

func readOnce(_ svc: ServiceClient) -> Bool {
    guard let ev = copyEvent(svc, eventType, 0, 0)?.takeRetainedValue() else { return false }
    sampler.emit(getFloat(ev, field(eventType, 0)),
                 getFloat(ev, field(eventType, 1)),
                 getFloat(ev, field(eventType, 2)))
    return true
}

// Pull one sample up front so a hard failure surfaces immediately rather than
// as silence.
let pullWorked = services.contains(where: { readOnce($0) })
if !pullWorked {
    FileHandle.standardError.write("""
        note: IOHIDServiceClientCopyEvent returned no event for \(label) \
        (the service is motion-restricted). Falling through to push callbacks.\n
        """.data(using: .utf8)!)
}

if pollHz > 0 {
    print("polling at \(pollHz) Hz — tilt the machine, tap the palm rests. Ctrl-C to stop.\n")
    let timer = Timer(timeInterval: 1.0 / pollHz, repeats: true) { _ in
        for svc in services {
            if readOnce(svc) { break }
        }
    }
    RunLoop.current.add(timer, forMode: .common)
} else {
    print("push callbacks — tilt the machine, tap the palm rests. Ctrl-C to stop.\n")
    let onEvent: FnEventCallback = { _, _, _, event in
        guard let event,
              let gt = Shared.getTypeFn,
              let gf = Shared.getFloatFn,
              let s = Shared.sampler else { return }
        let t = gt(event)
        guard t == Shared.eventType else { return }
        s.emit(gf(event, field(t, 0)), gf(event, field(t, 1)), gf(event, field(t, 2)))
    }
    registerCallback?(client, onEvent, nil, nil)
    scheduleRunLoop?(client, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

CFRunLoopRun()

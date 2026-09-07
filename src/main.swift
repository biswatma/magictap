// magictap — tap the chassis of an Apple silicon MacBook to trigger actions.
//
//   magictap info              show the matched sensor and its capabilities
//   magictap stream            print live accelerometer samples
//   magictap record FILE.csv   capture samples to CSV for offline tuning
//   magictap tap               detect taps and report side + onset signature
//   magictap replay FILE.csv   re-run the detector over a recorded session
//   magictap run               watch for gestures and run the bound commands
//   magictap calibrate L R     derive a left/right boundary from two recordings

import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print("""
    magictap — chassis tap detection for Apple silicon MacBooks

    USAGE
      magictap info
      magictap stream [--gyro] [--n=N] [--hz=RATE]
      magictap record FILE.csv [--n=N] [--hz=RATE]
      magictap replay FILE.csv [--expect=left|right] [--threshold=G]
                               [--split=CORR] [--invert]
      magictap run [--double=CMD] [--left=CMD] [--right=CMD]
                   [--double-window=SEC] [--threshold=G] [--quiet]
                   [--input-window=SEC] [--cooldown=SEC] [--no-guard]
      magictap run --check
      magictap calibrate LEFT.csv RIGHT.csv [--threshold=G]
      magictap tap [--threshold=G] [--split=CORR] [--invert]
                   [--refractory=SEC] [--hz=RATE] [--n=N] [--verbose]

    OPTIONS
      --hz=RATE       requested sensor rate; the BMI282 supports
                      50/100/200/400/800 (default 800)
      --threshold=G   peak linear acceleration for a tap, in g (default 0.06)
      --split=CORR    corr(x,z) boundary between sides (default -0.287);
                      above it is a left tap. Re-derive per machine with
                      tools/analyze.py
      --invert        flip the left/right assignment
      --refractory=S  minimum gap between taps, in seconds (default 0.25)
      --verbose       in tap mode, also print the peak vector
      --n=N           stop after N samples (stream/record) or taps (tap)
      --expect=SIDE   in replay, the true label, to score classification

    RUN MODE
      --double=CMD        shell command for a double tap. Defaults to
                          `screencapture -c -x`: whole screen to the clipboard.
                          Use `screencapture -c -i -x` to drag a region instead.
      --left=CMD          command for a single tap on the left
      --right=CMD         command for a single tap on the right
      --double-window=SEC max gap between the two taps (default 0.45)
      --quiet             only log gestures that actually ran a command
      --input-window=SEC  ignore taps within SEC of a keystroke or click
                          (default 0.35). Typing is a series of impacts on the
                          same chassis, and two of them inside the double-tap
                          window otherwise look exactly like a double tap.
      --cooldown=SEC      ignore taps within SEC of a fired action (default
                          0.70), so an action cannot retrigger itself
      --no-guard          accept every tap, ignoring both guards above

    CALIBRATE
      Feeds two labelled recordings through the detector and reports the
      corr_xz boundary that best separates them, the accuracy it achieves and
      the detection threshold implied by how hard the taps were. This is the
      same computation the app's guided calibration performs, so a result here
      predicts what the app would derive from the same taps.

    Commands run under /bin/sh with MAGICTAP_GESTURE (and MAGICTAP_SIDE for
    single taps) set in the environment. Binding no single-tap command keeps
    lone taps silent and avoids their wait.
    """)
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, !command.hasPrefix("-") else { usage() }
args.removeFirst()

// MARK: - Flags

var useGyro = false
var limit = Int.max
var requestedHz = 800.0
var verbose = false
var config = TapConfig()
config.refractory = 0.12  // measured floor before ringdown re-triggers
var recordPath: String?
var calibrateLeftPath: String?
var calibrateRightPath: String?
var expected: String?
var quiet = false
var checkOnly = false
var doubleWindow = 0.45
var actions = ActionRunner()
var doubleBound = false
var gate = TapGate()
var requireIsolation = true

if command == "record" || command == "replay" {
    guard let p = args.first, !p.hasPrefix("--") else { fail("\(command) needs a file path") }
    recordPath = p
    args.removeFirst()
}

if command == "calibrate" {
    guard args.count >= 2, !args[0].hasPrefix("--"), !args[1].hasPrefix("--") else {
        fail("calibrate needs two paths: a left-taps recording and a right-taps recording")
    }
    calibrateLeftPath = args[0]
    calibrateRightPath = args[1]
    args.removeFirst(2)
}

for arg in args {
    switch arg {
    case "--gyro": useGyro = true
    case "--quiet": quiet = true
    case "--no-guard": gate.enabled = false
    case "--no-calm": requireIsolation = false
    case "--check": checkOnly = true
    case "--invert": config.invert = true
    case "--verbose": verbose = true
    case "-h", "--help": usage()
    default:
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("unknown option: \(arg)") }
        let value = parts[1]
        switch parts[0] {
        case "--n":
            guard let v = Int(value) else { fail("--n needs an integer") }
            limit = v
        case "--hz":
            guard let v = Double(value), v > 0 else { fail("--hz needs a positive number") }
            requestedHz = v
        case "--threshold":
            guard let v = Double(value), v > 0 else { fail("--threshold needs a positive number") }
            config.threshold = v
        case "--refractory":
            guard let v = Double(value), v >= 0 else { fail("--refractory needs a number") }
            config.refractory = v
        case "--double":
            actions.double = value
            doubleBound = true
        case "--left": actions.singleLeft = value
        case "--right": actions.singleRight = value
        case "--input-window":
            guard let v = Double(value), v >= 0 else { fail("--input-window needs a number") }
            gate.inputWindow = v
        case "--cooldown":
            guard let v = Double(value), v >= 0 else { fail("--cooldown needs a number") }
            gate.cooldown = v
        case "--double-window":
            guard let v = Double(value), v > 0 else { fail("--double-window needs a positive number") }
            doubleWindow = v
        case "--expect":
            guard ["left", "right"].contains(value) else { fail("--expect must be left or right") }
            expected = value
        case "--split":
            guard let v = Double(value), v >= -1, v <= 1 else {
                fail("--split needs a correlation between -1 and 1")
            }
            config.split = v
        default:
            fail("unknown option: \(arg)")
        }
    }
}

// MARK: - Offline commands (no sensor required)

/// Runs the detector over a recording and returns every tap it found.
func detectTaps(inFileAt path: String, config: TapConfig) -> [Tap] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    let detector = TapDetector(config: config)
    var taps: [Tap] = []
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
        let cols = line.split(separator: ",")
        guard cols.count >= 4, let t = Double(cols[0]), let x = Double(cols[1]),
              let y = Double(cols[2]), let z = Double(cols[3]) else { continue }
        if let tap = detector.process(MotionSample(x: x, y: y, z: z, time: t)) {
            taps.append(tap)
        }
    }
    return taps
}

if command == "calibrate" {
    guard let leftPath = calibrateLeftPath, let rightPath = calibrateRightPath else {
        fail("calibrate needs two file paths")
    }

    let leftTaps = detectTaps(inFileAt: leftPath, config: config)
    let rightTaps = detectTaps(inFileAt: rightPath, config: config)

    print("left  \(leftPath): \(leftTaps.count) taps")
    print("right \(rightPath): \(rightTaps.count) taps")

    do {
        let result = try Calibration.compute(
            leftCorr: leftTaps.map(\.corrXZ),
            rightCorr: rightTaps.map(\.corrXZ),
            peaks: (leftTaps + rightTaps).map(\.peak))

        print("""

        boundary   corr_xz \(String(format: "%+.3f", result.split))\
        \(result.invert ? "  (inverted: above the boundary is a right tap)" : "")
        accuracy   \(String(format: "%.1f%%", result.accuracy * 100)) \
        on \(result.leftCount) left + \(result.rightCount) right taps
        d-prime    \(String(format: "%.2f", result.dPrime))
        margin     \(String(format: "%.3f", result.margin)) from the nearest tap
        clusters   left \(String(format: "%+.3f", result.leftMean)), \
        right \(String(format: "%+.3f", result.rightMean))
        threshold  \(String(format: "%.3f g", result.suggestedThreshold)) suggested

        \(result.verdict.summary) — \(result.verdict.advice)
        """)

        print("""

        To use it:  magictap run --split=\(String(format: "%.3f", result.split))\
        \(result.invert ? " --invert" : "")
        """)
        exit(0)
    } catch {
        fail("\ncalibration failed: \(error)")
    }
}

// MARK: - Replay (no sensor required)

if command == "replay" {
    guard let path = recordPath,
          let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(recordPath ?? "<none>")")
    }

    let detector = TapDetector(config: config)
    let gestures = GestureRecognizer(wantsSingles: false)
    gestures.doubleWindow = doubleWindow
    gestures.requireIsolation = requireIsolation
    var counts: [String: Int] = ["left": 0, "right": 0, "unknown": 0]
    var index = 0
    var gestureCount = 0
    var notIsolated = 0

    for rawLine in text.split(separator: "\n") {
        // Tolerate CRLF, which any CSV written on another tool may carry.
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
        let cols = line.split(separator: ",")
        guard cols.count >= 4, let t = Double(cols[0]), let x = Double(cols[1]),
              let y = Double(cols[2]), let z = Double(cols[3]) else { continue }
        guard let tap = detector.process(MotionSample(x: x, y: y, z: z, time: t)) else { continue }
        index += 1
        counts[tap.side.rawValue, default: 0] += 1
        switch gestures.feed(tap) {
        case .gesture: gestureCount += 1
        case .notIsolated: notIsolated += 1
        case .opened: break
        }
        let mark = expected.map { tap.side.rawValue == $0 ? " " : " MISS" } ?? ""
        print(String(format: "tap #%03d  %@  peak=%6.3f g  corr_xz=%+6.3f  bg=%.3f  n=%d%@",
                     index, tap.side.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0),
                     tap.peak, tap.corrXZ, tap.backgroundActivity, tap.sampleCount, mark))
    }

    print("\n\(index) taps — left \(counts["left"]!), right \(counts["right"]!), "
          + "unknown \(counts["unknown"]!)")
    print("\(gestureCount) double-tap gestures, \(notIsolated) taps ignored as not isolated")
    if let want = expected, index > 0 {
        let hits = counts[want]!
        print(String(format: "expected all %@: %d/%d correct (%.1f%%)",
                     want, hits, index, 100.0 * Double(hits) / Double(index)))
        exit(hits == index ? 0 : 1)
    }
    exit(0)
}

// MARK: - Connect

let kind: MotionKind = useGyro ? .gyro : .accelerometer
let source = MotionSource(kind: kind)

do {
    try source.connect()
} catch {
    fail("\(error)")
}

let properties = source.describeService()

if command == "info" {
    print("sensor: \(properties["model"] ?? "unknown") by \(properties["manufacturer"] ?? "unknown")")
    print("kind:   \(kind.name) (vendor page 0xFF00, usage \(kind.usage))")
    for key in ["sensor_rates", "ReportInterval", "motionRestrictedService"] {
        if let v = properties[key] { print("\(key): \(v)") }
    }
    print("""

    Reads go through the HID event system's push callbacks. The service is
    motion-restricted, so IOHIDDevice input reports and
    IOHIDServiceClientCopyEvent both return nothing on this hardware.
    """)
    exit(0)
}

let interval = Int((1_000_000.0 / requestedHz).rounded())
let accepted = source.requestInterval(microseconds: interval)

// MARK: - Commands

var samples = 0
var taps = 0
var meter = RateMeter()

switch command {
case "stream":
    print("\(properties["model"] ?? "sensor") — \(kind.name) @ requested \(Int(requestedHz)) Hz "
          + "(\(accepted ? "accepted" : "rejected")). Ctrl-C to stop.\n")
    source.start { s in
        samples += 1
        let hz = meter.tick(s.time)
        print(String(format: "#%06d  x=%+9.5f  y=%+9.5f  z=%+9.5f  |v|=%8.5f  %6.1f Hz",
                     samples, s.x, s.y, s.z, s.magnitude, hz))
        if samples >= limit { exit(0) }
    }

case "record":
    guard let path = recordPath else { fail("record needs an output path") }
    guard let out = OutputStream(toFileAtPath: path, append: false) else {
        fail("cannot open \(path) for writing")
    }
    out.open()
    func write(_ line: String) {
        let bytes = Array(line.utf8)
        out.write(bytes, maxLength: bytes.count)
    }
    write("t,x,y,z\n")
    print("recording \(kind.name) to \(path) — tap the chassis, Ctrl-C to stop.\n")

    let start = CFAbsoluteTimeGetCurrent()
    source.start { s in
        samples += 1
        write(String(format: "%.6f,%.6f,%.6f,%.6f\n", s.time - start, s.x, s.y, s.z))
        if samples % 200 == 0 {
            print(String(format: "  %d samples (%.1f s)", samples, s.time - start))
        }
        if samples >= limit {
            out.close()
            print("wrote \(samples) samples to \(path)")
            exit(0)
        }
    }

case "tap":
    if useGyro { fail("tap detection expects the accelerometer; drop --gyro") }
    let detector = TapDetector(config: config)
    print("""
    \(properties["model"] ?? "sensor") — tap detection
      threshold  \(config.threshold) g
      split      corr(x,z) \(config.split)\(config.invert ? " (inverted)" : "")
      refractory \(config.refractory) s
      rate       requested \(Int(requestedHz)) Hz (\(accepted ? "accepted" : "rejected"))

    Tap the chassis to the left and right of the trackpad. If the sides come
    out swapped, add --invert. If they are unreliable, recalibrate:
    record a labelled session per side and run tools/analyze.py.

    """)
    source.start { s in
        guard let tap = detector.process(s) else { return }
        taps += 1
        var line = String(format: "tap #%03d  %@  peak=%6.3f g  corr_xz=%+6.3f",
                          taps, tap.side.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0),
                          tap.peak, tap.corrXZ)
        let sinceInput = InputActivity.secondsSinceLastInput()
        if sinceInput < 0.35 {
            line += String(format: "  [typing %.2fs ago — run mode would ignore this]", sinceInput)
        }
        if verbose {
            line += String(format: "  corr_xy=%+6.3f  peakvec x=%+7.4f y=%+7.4f z=%+7.4f  n=%d  @%5.0f Hz",
                           tap.corrXY, tap.peakVector.x, tap.peakVector.y, tap.peakVector.z,
                           tap.sampleCount, tap.sampleRate)
        }
        print(line)
        if taps >= limit { exit(0) }
    }

case "run":
    if !doubleBound && actions.double == nil {
        actions.double = "screencapture -c -x"
    }
    if actions.double?.isEmpty == true { actions.double = nil }

    if checkOnly {
        let granted = CGPreflightScreenCaptureAccess()
        print("sensor:            \(properties["model"] ?? "unknown") (ok)")
        print("screen recording:  \(granted ? "granted" : "NOT granted")")
        if !granted {
            print("""

            Grant it in System Settings > Privacy & Security > Screen Recording
            for the app running magictap, then restart that app.
            """)
        }
        exit(granted ? 0 : 1)
    }

    let detector = TapDetector(config: config)
    let gestures = GestureRecognizer(wantsSingles: actions.wantsSingles)
    gestures.doubleWindow = doubleWindow
    gestures.requireIsolation = requireIsolation

    print("""
    \(properties["model"] ?? "sensor") — listening
      double tap  \(actions.double ?? "(unbound)")
      left tap    \(actions.singleLeft ?? "(unbound)")
      right tap   \(actions.singleRight ?? "(unbound)")
      threshold   \(config.threshold) g, refractory \(config.refractory) s
      window      \(doubleWindow) s
      guard       \(gate.enabled
                      ? "ignore taps within \(gate.inputWindow)s of typing, \(gate.cooldown)s after an action"
                      : "disabled")

    Ctrl-C to stop.

    """)

    // screencapture does not fail loudly without permission — it quietly
    // returns an image of the desktop picture with no windows in it.
    let usesCapture = [actions.double, actions.singleLeft, actions.singleRight]
        .compactMap { $0 }
        .contains { $0.contains("screencapture") }
    if usesCapture && !CGPreflightScreenCaptureAccess() {
        print("""
        WARNING: Screen Recording permission is not granted to this process.
        screencapture will produce a desktop-only image with no windows,
        without reporting an error.

        Grant it in System Settings > Privacy & Security > Screen Recording,
        for the app running magictap (Terminal, iTerm, VS Code...), then
        restart that app. Re-check with:  magictap run --check

        """)
    }

    func fire(_ g: Gesture) {
        let cmd = actions.command(for: g)
        if cmd == nil && quiet { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        let when = stamp.string(from: Date())
        if let cmd {
            actions.run(g)
            gate.noteActionFired(at: CFAbsoluteTimeGetCurrent())
            print("\(when)  \(g.name)  -> \(cmd)")
        } else {
            print("\(when)  \(g.name)  (unbound)")
        }
    }

    source.start { s in
        if let g = gestures.expire(now: s.time) { fire(g) }
        guard let tap = detector.process(s) else { return }

        if let reason = gate.evaluate(at: tap.time) {
            if !quiet {
                print(String(format: "          tap %@ peak=%.3f g  %@",
                             tap.side.rawValue, tap.peak, reason.explanation))
            }
            return
        }

        switch gestures.feed(tap) {
        case .gesture(let g):
            fire(g)
        case .notIsolated(let ratio):
            if !quiet {
                print(String(format: "          tap %@ peak=%.3f g  ignored — machine already moving (bg %.2f)",
                             tap.side.rawValue, tap.peak, ratio))
            }
        case .opened:
            if !quiet {
                print(String(format: "          tap %@ peak=%.3f g corr_xz=%+.3f bg=%.2f",
                             tap.side.rawValue, tap.peak, tap.corrXZ, tap.backgroundActivity))
            }
        }
    }

default:
    fail("unknown command: \(command) (try: info, stream, record, tap, replay, run, calibrate)")
}

CFRunLoopRun()

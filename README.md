# magictap

Chassis tap detection for Apple silicon MacBooks — knock the case beside the
trackpad, trigger an action.

## The hardware

Apple silicon MacBooks from the 2021 MacBook Pro / 2022 MacBook Air redesigns
carry a **Bosch BMI282** 6-axis IMU behind the Sensor Processing Unit. It is not
on the SMC. It appears as two vendor-defined HID devices:

| node | usage page | usage | notes |
|------|-----------|-------|-------|
| `accel` | `0xFF00` | 3 | accelerometer, calibrated output in **g** |
| `gyro`  | `0xFF00` | 9 | gyroscope |
| `las`   | `0x20`   | `0x8A` | lid angle sensor |
| `als`   | — | — | ambient light |

Confirm on any machine with:

```sh
ioreg -r -n accel -l -w0
```

Useful properties from that dump:

- `model = "BMI282"`, `manufacturer = "Bosch"`
- `sensor_rates = "50 100 200 400 800"` — up to **800 Hz**, despite the
  advertised `ReportInterval` of 8000 µs (125 Hz)
- `motionRestrictedService = Yes` — the reason the obvious API returns nothing
- `ReportDescriptor = <0600ff0a0300a101150026ff00750895168102c0>`, which decodes
  to a bare 22-byte opaque input blob with no report ID

## Getting data out

Three paths, only one of which works:

1. **`IOHIDDevice` + input report callback** — the device opens successfully and
   then delivers nothing, because the service is motion-restricted.
   `probe/accelprobe.swift` demonstrates this dead end.
2. **`IOHIDServiceClientCopyEvent`** (pull) — returns null for the same reason.
3. **`IOHIDEventSystemClientRegisterEventCallback`** (push) — **works.**
   Delivers typed `kIOHIDEventTypeAccelerometer` (13) events with calibrated
   float axes, at the full 800 Hz.

Path 3 needs private symbols, resolved at runtime via `dlsym` in
[src/HIDMotion.swift](src/HIDMotion.swift). No entitlement and no Input
Monitoring grant were needed on macOS 26 — but private API means this cannot
ship on the Mac App Store, and could break in a future release.

Measured noise floor sitting still: **~0.005 g**. The default tap threshold of
0.06 g sits about 12× above it.

## Build

```sh
./build-app.sh          # -> build/MagicTap.app and build/MagicTap-1.0.0.dmg
./build-app.sh --no-dmg # app only
./build.sh              # the CLI, -> bin/magictap
```

## The app

`MagicTap.app` is a menu bar app — no Dock icon, no window unless you open one.
It carries the Screen Recording permission itself, which is the main reason it
exists: granting that to a terminal is awkward and grants it to everything you
ever run there.

**Requires macOS 14 or later** (ScreenCaptureKit's `SCScreenshotManager`).

**Install:** open the DMG, drag MagicTap to Applications, launch it. It is not
notarised by Apple, so the first launch is blocked — right-click the app,
choose Open, confirm. Once only.

Install to `/Applications` *before* granting Screen Recording. The permission
is tied to the app's identity and location, so granting it first and moving the
app afterwards means granting it again.

**Menu bar:** the tap icon sits with Wi-Fi and battery. Filled means active,
hollow means paused. The menu shows the bound action, the last gesture, a
session counter, an Enabled toggle, Setup & Permissions, and Quit.

**Setup window** (opens on first launch, or from the menu):

- *Setup* — sensor detection, Screen Recording status with a Grant button, and
  usage instructions, plus a live tap monitor showing side, force and `corr_xz`
  as you tap. Use it to check detection before trusting a binding.
- *Settings* — an action per gesture chosen from the catalogue below, plus tap
  strength, double-tap window, swap left/right, ignore taps while typing,
  feedback sound, and launch at login.

**Log:** `~/Library/Logs/MagicTap.log`, reachable from the menu as *Open Log…*.
It records every tap, every gesture and every suppression with its reason — a
menu bar app has no console, and diagnosing the typing problem without one was
harder than it needed to be.

## Actions

51 built-in actions, grouped in the picker. Five take a parameter, shown as a
text field under the picker when selected.

| group | actions |
|---|---|
| Screenshots & clipboard | Screenshot → Clipboard / Desktop / select area, Copy, Paste, Paste without formatting, Undo, Redo |
| Media & volume | Mute toggle, Volume up/down, Play/Pause, Next/Previous track |
| Input, display & focus | Microphone mute toggle, Brightness up/down, Keyboard backlight up/down, Toggle Focus… |
| Window & workspace | Mission Control, Spotlight, Quick Note, Minimize, Close, Left half, Right half, Maximize, Toggle full screen, Hide front app, Hide others, Previous/Next Space, Switch to previous app, App switcher, Quit front app |
| Lock, sleep & screensaver | Lock screen, Start screen saver, Sleep display |
| Connectivity | Wi-Fi on/off, Bluetooth on/off, Eject external disks |
| System status & utilities | Empty Trash, Battery status, New email, Current weather |
| Custom | Press keyboard shortcut…, Open application…, Open URL…, Run Shortcut…, Run a custom command… |

### How they are carried out

Four mechanisms, chosen per action:

- **Synthetic key events** (`CGEvent`) for anything the system already binds —
  ⌘C, ⌘Tab, Spotlight, Spaces, window commands.
- **NX system-defined events** for media, brightness and keyboard backlight.
  These are not ordinary keystrokes and cannot be sent as such.
- **The Accessibility API** for moving and resizing another app's windows.
- **AppleScript, CoreWLAN, IOBluetooth and shell** for the rest.

Where a permission-free route exists it is preferred, so fewer actions are
gated: volume goes through AppleScript rather than the volume keys, and Lock
Screen calls `CGSession -suspend` rather than synthesising ⌃⌘Q. Ejecting disks
enumerates mounted volumes rather than scripting Finder, avoiding an Automation
prompt.

### Accessibility permission

Synthesising input and repositioning another app's windows are both gated
behind Accessibility. Roughly half the catalogue needs it; screenshots, volume,
lock, sleep, connectivity and the `open`-based actions do not. The setup window
shows it as its own step, and the settings picker flags any action you select
that needs a permission you have not granted.

As with Screen Recording, MagicTap refuses to start an action whose permission
is missing rather than letting the system prompt fire on every tap.

### Known caveats

- **Toggle Focus…** — macOS exposes no public API for Focus modes, so this runs
  a Shortcut you name. Create one that sets the Focus you want.
- **App switcher** — sends ⌘Tab. Stepping further needs the key held down,
  which a tap cannot express.
- **Current weather** — opens the Weather app rather than reporting inline.
- **Bluetooth** — uses IOBluetooth's private power control, resolved at runtime
  and reported as unavailable if a future macOS removes it.
- **Empty Trash** — scripts Finder, so macOS asks for Automation permission the
  first time.

### Screenshots are captured in-process

The first version shelled out to `/usr/sbin/screencapture`. That re-triggered
the Screen Recording prompt on **every capture**: TCC attributes a spawned
binary's request to that binary rather than reliably to the app that launched
it, so the grant never stuck.

`Screenshot.swift` now captures through **ScreenCaptureKit**
(`SCScreenshotManager`) in-process and writes PNG and TIFF to the pasteboard,
which makes the permission unambiguously MagicTap's own — asked once, then
remembered. It picks the display under the pointer and matches the backing
scale so a Retina capture is not downsampled. Interactive region select still
shells out, because that crosshair UI belongs to the system tool.

The engine also refuses to start any capture while permission is missing. That
refusal is what stops the prompt loop: it reports the problem in the menu and
opens the setup window **once per launch** instead of letting the system dialog
fire on every tap.

This is why the app requires macOS 14 — `SCScreenshotManager` needs it.

### Ad-hoc signing costs the permission on every rebuild

An ad-hoc signature is derived from the binary, so every rebuild is a new code
identity, and macOS treats it as a **different app**. During development this
accumulated four separate TCC records for one bundle ID, each prompting afresh:

```sh
tccutil reset ScreenCapture com.biswa.magictap   # clears them all
```

So: grant the permission **after** the final build, and re-granting is expected
after any rebuild. Clear the stale records first with the command above.

The real fix is a stable signing identity. A paid Developer ID certificate
solves it along with Gatekeeper. A self-signed code-signing certificate created
in Keychain Access and used as `codesign -s "<name>"` in `build-app.sh` also
gives a stable identity, without the Gatekeeper benefit.

### Building and signing notes

The app is arm64-only with an explicit `macos14.0` deployment target. Both are
deliberate: the default target would be the *building* machine's macOS, which
produces a binary that crashes on older systems instead of declining to launch.
Intel is no loss, since those Macs have no sensor to read.

The signature is ad-hoc (`codesign -s -`). That is enough for local use, but an
ad-hoc signature changes whenever the binary does — so after a rebuild macOS may
treat MagicTap as a new app and drop its Screen Recording grant. A real Developer
ID certificate would fix that, along with the Gatekeeper prompt.

## Use

```sh
bin/magictap info                    # matched sensor and its capabilities
bin/magictap stream                  # live samples with a sliding-window rate
bin/magictap record taps.csv         # capture to CSV for offline tuning
bin/magictap tap                     # detect taps, report side + corr_xz
bin/magictap replay left.csv --expect=left   # score the detector on a recording
bin/magictap run                     # watch for gestures, run bound commands
bin/magictap run --check             # verify sensor + screen recording permission
bin/magictap run --no-guard          # accept taps during typing (calibration only)
```

## Gestures and actions

```sh
bin/magictap run                                  # double tap -> screenshot to clipboard
bin/magictap run --double='screencapture -c -i -x'  # drag a region instead
bin/magictap run --left='open -a Music' --right='osascript -e "tell app \"Music\" to next track"'
```

`run` binds shell commands to gestures. The default double-tap action is
`screencapture -c -x` — whole screen to the clipboard. Commands execute under
`/bin/sh` with `MAGICTAP_GESTURE` (and `MAGICTAP_SIDE` for single taps) in the
environment, and are launched without waiting, so a slow or interactive action
cannot stall sample delivery.

A double tap fires the instant the second tap is classified. Only a *single*
tap has to wait out `--double-window` (default 0.45 s) to prove no second tap
is coming — so leaving the single-tap bindings unset costs nothing and keeps
stray knocks silent.

### Typing is not a tap

Keystrokes and trackpad clicks are impacts on the same chassis the sensor
reads. They clear the tap threshold easily, and two of them inside the
double-tap window are indistinguishable from a deliberate double tap — so
without a guard the app fires continuously while you type.

`TapGate` asks the window server how long it has been since real input, via
`CGEventSource.secondsSinceLastEventType`. Taps within 0.35 s of a keystroke or
click are dropped, as are taps within 0.70 s of a fired action, so an action
cannot retrigger itself. That API needs **no** Accessibility or Input
Monitoring permission — it reports timing only, never content or keycodes.

The gate sits *outside* `TapDetector`, deliberately: the detector stays a pure
function of the sample stream, so `replay` remains deterministic and its 40/40
score keeps meaning something. `magictap tap` also leaves the gate off, since
it is a calibration tool — it just flags taps that `run` would have ignored.

Three other suspects were measured and cleared first, none of them the cause:

| suspect | test | result |
|---|---|---|
| detector misfiring at rest | 20 s untouched | 0 taps |
| speaker sound shaking the chassis | Pop played 8× at 81% volume | 0 taps |
| the screenshot action itself | `screencapture` run 8× | 0 taps |

### A tilt is not a tap

The first version tracked gravity with an exponential average that only updated
while the residual was small — frozen during a transient, so a hard tap could
not absorb itself into the baseline. That deadlocks. Tilt the machine or hold it
in your lap and the residual never returns to zero, so gravity never re-learns,
so **every sample reads as a tap, forever**. Observed in the wild as a burst of
identical peaks at the refractory floor:

```
tap left  peak=0.761   tap right peak=0.729
tap right peak=0.736   tap right peak=0.738
```

Identical magnitudes repeating every ~140 ms is the signature: a real tap
decays within tens of milliseconds, so a constant peak is a constant *offset*
being re-detected.

Two changes fix it, and both are needed:

1. **Gravity resync.** If the residual stays above the transient gate for
   `gravityResyncAfter` (0.35 s, far longer than any real tap), the baseline
   snaps to the current orientation and in-flight detection state is dropped.
   Gravity is also seeded from an average of the first 32 samples rather than
   one sample, so a machine that is moving at launch does not bias it forever.
2. **A tap must settle.** Emission additionally requires the residual to be
   back below the gate. A tap rings and dies; a posture change does not. This
   is what removes the false taps in the 0.35 s *before* a resync fires.

Verified against four scenarios:

| scenario | expected | result |
|---|---|---|
| 6 s tilt held | 0 taps | 0 |
| 12 s laptop on a moving lap | 0 taps | 0 |
| tapping while tilted | 6 taps | 6, correct side |
| the labelled recordings | 40 taps | 40/40 |

So MagicTap works on a lap: once the posture settles the baseline follows it,
and taps register against the new orientation.

### Why refractory is 0.12 s

Two taps can be no closer together than `TapConfig.refractory`, so double-tap
support needs it low — but too low and the ringdown of one hard tap registers
as a second tap. Replaying the labelled sessions across values located the
floor exactly:

| refractory | left.csv (20 real taps) | right.csv (20 real taps) |
|---|---|---|
| 0.25 s – 0.12 s | 20 | 20 |
| 0.10 s | **25** | 21 |
| 0.08 s | **33** | **31** |

0.12 s is the default: the lowest value with no spurious re-triggers.

### Screen Recording permission

`screencapture` does not fail loudly without it — it quietly returns an image
of the desktop picture with no windows. `run` preflights the permission with
`CGPreflightScreenCaptureAccess` and warns; `run --check` reports it and exits
non-zero. Grant it to the app that runs magictap (Terminal, iTerm, VS Code),
then restart that app.

### How left vs. right works

Side comes from **`corr(x, z)`** — the Pearson correlation between the x and z
waveforms over a window around the peak (10 ms before, 40 ms after). Struck
off-centre, the chassis pivots, so lateral and vertical motion couple with a
sign that depends on which side of the pivot was hit.

Measured over 42 labelled taps on a MacBookPro18,4:

| | left | right |
|---|---|---|
| `corr_xz` mean | +0.317 | −0.804 |
| observed range | +0.05 … +0.29 | −0.71 … −0.84 |

d′ = 5.71, 100% separation, boundary at −0.287. Replaying both labelled
sessions through the shipped detector scores 40/40.

A correlation is **scale-invariant**, so tap force cannot leak into it. That
matters: the two labelled sessions were not force-matched (right taps averaged
0.46 g against left at 0.39 g), and peak force across the set ranged 0.28–0.59 g
with no effect on classification. The `peak_g` control in `analyze.py` exists to
catch exactly this kind of confound.

An earlier design used the sign of a single axis at tap onset. It failed:
vertical motion dominates every tap, and because the IMU is not centred the two
sides are not mirror images — one side produces lateral components at 25–40% of
peak magnitude, the other only 4–5%. The sides differ in lateral *magnitude*,
not sign, so a sign test at zero was reading noise.

### Recalibrating on other hardware

The boundary above is specific to this chassis. On a different model:

```sh
./bin/magictap record left.csv      # tap ONLY left of the trackpad, ~20 times
./bin/magictap record right.csv     # tap ONLY right, ~20 times
python3 tools/analyze.py left.csv right.csv
```

Vary tap force deliberately within each session, and keep the machine on the
same surface for both — a desk and a lap resonate differently, and that
difference would show up as a fake discriminator.

`analyze.py` segments the taps, extracts force-normalised candidate features
(peak direction, onset direction at several fractions, per-axis energy split,
signed impulse, cross-axis correlation), and ranks them by separation, with
leave-one-out accuracy for the best linear combinations. Feed the winning
boundary back in with `--split=`, adding `--invert` if the sides come out
swapped, then check it with:

```sh
./bin/magictap replay left.csv --expect=left
./bin/magictap replay right.csv --expect=right
```

## Layout

```
src/HIDMotion.swift    sensor access — private symbol bindings, MotionSource, RateMeter
src/TapDetector.swift  gravity tracking, peak detection, side classification
src/Gesture.swift      single/double tap grouping, shell action runner
src/InputActivity.swift  typing/click guard and post-action cooldown
src/main.swift         CLI
app/Support.swift      settings, permission checks, rolling log, login item
app/Actions.swift      the 51-action catalogue with groups and requirements
app/ActionExecutor.swift  key synthesis, media keys, window placement, system toggles
app/Screenshot.swift   in-process capture via ScreenCaptureKit
app/TapEngine.swift    sensor + detector + gestures, as observable app state
app/SetupWindow.swift  SwiftUI onboarding and settings
app/MenuBar.swift      status item and menu
app/main.swift         app entry point
app/tools/make-icon.swift  renders the .icns from an SF Symbol
probe/accelprobe.swift the IOHIDDevice path that does not work, kept as a record
probe/sensorprobe.swift first working spike via the event system
tools/analyze.py       offline search for a left/right discriminator
```

## Status

Working end to end: sensor access at 800 Hz, tap detection, left/right
classification (40/40 on labelled replay), gestures bound to any of 51
built-in actions, and a menu bar app packaged as a DMG.

Known limits: the private HID event-system symbols rule out the Mac App Store
and could break in a future macOS; the ad-hoc signature means a rebuild can
cost the Screen Recording grant; and the corr(x,z) boundary is calibrated to
one chassis — other models need `tools/analyze.py` re-run.

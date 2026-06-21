# SlapShift (clone of an existing app) only for macbooks*

A menu-bar macOS app that triggers app/URL/Focus-mode actions when you physically
slap your MacBook — inspired by [slapshift.app](https://slapshift.app/). This is
an independent, from-scratch reimplementation (not the original app's binary or
source), built to match its real design language and feature set: warm parchment
background, terracotta accent, editorial Newsreader serif type, pixel motion-line
mark, onboarding/calibration flow, live slap meter, and Input Monitoring permission
handling.

This is a personal tool, not a commercial product — there's no licensing, paywall,
telemetry, or marketing onboarding survey. Just detection + actions + a UI that
doesn't feel like a default SwiftUI form.

## Features

- **1, 2, or 3 consecutive slaps** fire independently configurable modes. Each
  mode can chain multiple actions: open an app, open a URL, activate a Focus mode
  (via a Shortcuts.app automation), or quit an app.
- **Real accelerometer-based detection** — not a fake/simulated demo. Reads the
  Mac's built-in motion sensor directly via the public IOKit HID API.
- **Instant single-slap response.** A 1-slap action fires the moment it's
  unambiguous (i.e. no 2-slap mode is configured to conflict with it) instead of
  always waiting out the multi-slap window — see [Responsiveness](#responsiveness)
  below.
- **Live calibration meter** with a gradient fill that shifts color as you
  approach the slap threshold, a peak-pulse marker, and a "waiting for next
  slap…" indicator during a genuinely ambiguous multi-slap window.
- **Animated onboarding** with step-progress dots, slide transitions between
  steps, and a spring-animated success check on each calibration step.
- **Animated HUD** (scale + fade in/out, intensity glow that scales with slap
  count) instead of an instant on/off panel.
- **Menu bar only** — no Dock icon, no persistent window; lives entirely behind
  the hand-tap status item.
- **Launch at login**, lifetime slap counter, and a headless self-test mode for
  regression-checking changes without any GUI interaction.

## How detection works

- Reads the built-in accelerometer (a Bosch BMI286, exposed on Apple Silicon
  as an `AppleSPUHIDDevice` at HID usage page `0xFF00` / usage `0x03`) through
  the **public** `IOHIDDevice` API — `IOHIDDeviceCreate`, `IOHIDDeviceOpen`,
  `IOHIDDeviceSetProperty`, `IOHIDDeviceRegisterInputReportCallback`,
  `IOHIDDeviceScheduleWithRunLoop`. No private symbols, no dlopen/dlsym — see
  `AccelerometerMonitor.swift`. The device's matching criteria and the
  impact-sensitive byte offset in its raw 22-byte report were both determined
  empirically on real hardware (`ioreg -p IOService -c IOHIDDevice -l` for the
  former; physically slapping the hardware while dumping raw report bytes via
  `SLAPSHIFT_DUMP_RAW=1` for the latter), since the report descriptor exposes
  no public per-field schema. Reports arrive at roughly 800Hz on the test
  machine — the hardware is not the bottleneck for responsiveness.
- Like the real app, this requires **Input Monitoring** permission (macOS
  treats raw motion/HID streams as input). The onboarding flow requests it
  via the public `IOHIDRequestAccess`/`IOHIDCheckAccess` APIs and links
  straight to System Settings if denied.
- A slap is confirmed only when **3 of 5** independent statistical checks agree
  on the same buffer window: high-pass impulse, STA/LTA energy ratio, CUSUM
  shift, kurtosis spike, and MAD outlier (`SlapDetector.swift`'s `SlapVoting`).
- 1, 2, or 3 consecutive slaps (within a configurable window) fire one of three
  configurable modes.

## Responsiveness

Two real, empirically-diagnosed issues made the app feel "broken" or "slow" even
when the hardware pipeline was working correctly:

1. **Every slap used to wait the full multi-slap window (previously 600ms)
   before firing anything** — even a 1-slap-only action, which is the most
   common case. Fixed: `SlapDetector.registerSlap` now fires immediately
   whenever there's no enabled slot bound to the next higher slap count (i.e.
   no ambiguity left to resolve), and only waits out the window when a real
   2-or-3-slap mode could still be coming. While waiting, `isArmedForMoreSlaps`
   flips true and the Settings meter shows a "waiting for next slap…" indicator
   instead of going silent.
2. **Default sensitivity was tuned for a sensor range it didn't match.** This
   Mac's accelerometer is configured for a narrow ±2g range, so a genuine tap
   only reaches ~1.4-1.6g (resting baseline is already ~1.2g from gravity) —
   right on the edge of the old default's detection band, so normal-force taps
   were inconsistently missed. A higher sensitivity (0.88) was tried and
   measured to fix that — but it was empirically *rejected* after it
   false-triggered from incidental keyboard-typing vibration during automated
   testing (confirmed via a `SLAPSHIFT_DEBUG_SEQ=1` trace showing a stray
   `registerSlap` firing mid-test with nobody touching the trackpad). The
   shipped default (0.77) was validated this session via a real physical-tap
   run with the detector listening the entire time: it caught a genuine slap
   and produced zero false positives while the machine sat quietly. If you
   want to retune this, change `sensitivity` in Settings (or `AppConfig.default`
   for new installs) and re-test both "does a normal tap register" and "does
   typing for 30s produce zero false fires" before keeping a change.

## Build & run

```bash
swift build
.build/debug/SlapShift   # runs as a menu-bar-only (no Dock icon) app
```

First launch walks you through Input Monitoring permission + a real 1/2/3-slap
calibration (with a "simulate, no hardware needed" escape hatch at every step).
Afterward, click the **hand.tap** icon in the menu bar → **Open Settings…** to
edit modes, sensitivity, the multi-slap time window, launch-at-login, and to
use the **Slap! / Slap x2 / Slap x3** test buttons.

## Verified end-to-end (headless self-test)

`SLAPSHIFT_AUTOTEST=1 .build/debug/SlapShift` drives the full pipeline without
any GUI interaction — injects 1/2/3 simulated slaps, confirms each resolves to
the right mode, runs its actions, and reports the lifetime counter. Useful for
regression-checking after changes; note that the real hardware listener stays
active during this test too, so genuinely loud/vibrating environments (or
typing on the same machine while it runs) can inject real extra slaps into the
log — that's expected, not a bug in the test harness.

Real bugs caught and fixed this way during development:

1. **HUD double-free crash**: the on-screen HUD window used AppKit's default
   `isReleasedWhenClosed = true` while also being held in a strong `static var`.
   Closing a previous HUD to show a new one double-released it, corrupting
   memory and crashing during the next autorelease pool drain. Fixed by setting
   `isReleasedWhenClosed = false` on the HUD panel.
2. **Dropped fast slaps**: chaining simulated slaps via independent
   `DispatchQueue.main.asyncAfter` deadlines hit GCD's timer coalescing, landing
   two "200ms apart" calls back-to-back and tripping the anti-double-count
   refractory guard. Fixed by chaining each simulated slap off the previous
   one's actual firing (`SlapDetector.simulateSlaps`) instead of scheduling
   independent absolute deadlines.
3. **Latency on every fire** and **sensitivity/false-positive tradeoff** — see
   [Responsiveness](#responsiveness) above.

## Known limitation: accelerometer access

If Settings shows the listening status in red/orange, the accelerometer
device wasn't found, didn't open, or never produced a report. Use
**Slap! / x2 / x3** to test the full pipeline (mode firing, HUD, actions)
regardless. Likely causes, in order of likelihood:

- Input Monitoring must be granted in System Settings → Privacy & Security
  → Input Monitoring, or `IOHIDCheckAccess` blocks real samples outright
  before the device is even opened.
- `AppleSPUHIDDevice` (the IOClass this code matches on) or the `0xFF00`/`0x03`
  usage page/usage pair could differ on non-Apple-Silicon Macs or future
  hardware — re-run `ioreg -p IOService -c IOHIDDevice -l` and look for an
  `AppleSPUHIDDevice` whose `DeviceUsagePairs` matches the accelerometer
  signature, then update `accelUsagePage`/`accelUsage` in
  `AccelerometerMonitor.swift`.
- The byte offset (and 16384 LSB/g scale) used in `magnitude(from:length:)`
  was reverse-engineered on one specific machine; a different sensor model
  or report layout would need the same `SLAPSHIFT_DUMP_RAW=1` physical-tap
  procedure re-run to confirm.
- Set `SLAPSHIFT_DEBUG_HID=1` to get a live `REAL SAMPLE: mag=X.XXXg` /
  `REAL SLAP DETECTED` stderr trace for diagnosing exactly where the
  pipeline stalls. Set `SLAPSHIFT_DEBUG_SEQ=1` to trace the consecutive-slap
  counter (`registerSlap`/`finalizeSlapSequence`) if mode counts seem wrong.

## Configuring a Focus-mode slot

macOS has no public API to switch Focus modes programmatically. Create a
Shortcut in Shortcuts.app (e.g. named "Focus") with a "Set Focus" action, then
add an **Activate Focus** action in a mode with target `Focus` — SlapShift
runs `shortcuts run Focus` for you.

## Design system

- Background `#EDE3CE`, surface `#F7F1E3`, accent (terracotta) `#D2592E` —
  see `Theme.swift`.
- Typography: Newsreader (regular + italic), an OFL-licensed Google Font
  bundled under `Sources/SlapShift/Resources/Fonts/` with its `OFL.txt`.
- `PixelImpactMark` is an original small Canvas-drawn glyph echoing the real
  app's pixel-art motion lines — not a copy of its bundled assets.
- `Theme.Spacing` / `Theme.Motion` are a small design-token layer (spacing
  scale, shared animation durations/curves) used across the onboarding,
  settings, HUD, and meter views instead of ad-hoc padding/animation literals.
- Buttons (`PrimaryButtonStyle`/`SecondaryButtonStyle`) have hover feedback in
  addition to the press state; `DisabledRowStyle` dims and disables
  interaction on a disabled slot's action list.

## Project layout

```
Sources/SlapShift/
├── main.swift                    # entry point
├── AppDelegate.swift             # menu bar status item + wiring + self-test hook
├── Theme.swift                   # colors, fonts, spacing/motion tokens, button/card styles, pixel mark
├── Models.swift                  # Slot/SlotAction/AppConfig + default config
├── ConfigStore.swift             # JSON persistence (~/Library/Application Support/SlapShift/modes.json)
├── InputMonitoringPermission.swift  # IOHIDCheckAccess/IOHIDRequestAccess wrapper
├── AccelerometerMonitor.swift    # public IOHIDDevice accelerometer stream
├── SlapDetector.swift            # 5-algorithm voting + consecutive-slap counter + latency logic
├── SlapMeter.swift               # live calibration meter (SwiftUI)
├── ActionRunner.swift            # executes slot actions (Process lifetime-safe)
├── LaunchAtLogin.swift           # SMAppService wrapper
├── HUDOverlay.swift              # transient, animated on-screen feedback
├── OnboardingView.swift          # first-run permission + calibration flow
└── SettingsView.swift            # SwiftUI settings window + mode editor
```

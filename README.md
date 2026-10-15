<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/AppIcon-dark.png">
    <img src="assets/AppIcon.png" width="128" height="128" alt="PureMouse icon">
  </picture>
</p>

<h1 align="center">PureMouse</h1>

<p align="center">
  A tiny, offline replacement for Logi Options+ on macOS.<br>
  Button mapping, gestures, DPI and smooth scrolling for Logitech mice, with no account, no
  network and no background bloat.
</p>

<p align="center">
  <a href="https://github.com/mblauberg/PureMouse/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mblauberg/PureMouse?color=0A84FF"></a>
  <a href="https://github.com/mblauberg/PureMouse/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mblauberg/PureMouse/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-universal-555555">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-2EA44F">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/github/license/mblauberg/PureMouse?color=2EA44F"></a>
</p>

---

PureMouse communicates directly with Logitech mice over the HID++ 2.0 protocol, whether connected
via a Bolt or Unifying receiver or over Bluetooth. It maps mouse buttons to macOS actions and can
replace default system scrolling with responsive smooth scrolling. Running as a lightweight
background agent with no window and no menu, it uses under 10 MB of memory and consumes zero CPU
while the mouse is idle.

## Features

- **Button mapping.** Map any button to Mission Control, App Exposé, Show Desktop, Launchpad, the
  next or previous Space, back and forward (as trackpad swipes), any keystroke, or a shell
  command.
- **Gestures.** Hold the thumb button and move the mouse up, down, left or right for four
  additional actions, plus one for a plain click.
- **Smooth scrolling.** Pixel-precise, accelerated scrolling on both wheels, synchronised with the
  display's refresh rate.
- **Hardware settings.** DPI, wheel directions, ratchet or free-spin mode (with a button to toggle
  it), and SmartShift.
- **Survives reconnects.** The mouse forgets its settings whenever it sleeps, reconnects or
  switches between a receiver and Bluetooth; PureMouse reapplies them automatically on every
  reconnect and after the Mac wakes.
- **Leaves no trace.** On quit or logout, PureMouse restores the mouse to its native behaviour.
  Nothing is stored on the mouse or receiver, so they behave normally on any other computer.
- **Private by design.** No network access, no account, no telemetry, and no external dependencies.

## Supported mice

PureMouse is built and tested with the **MX Master 3S**. It supports any Logitech HID++ 2.0 mouse
that reports adjustable DPI or includes a button named in your config, so other recent Logitech
mice (MX Master 3, MX Anywhere and similar) should work for the features they have. Run
`puremouse probe` to see what a mouse supports, and please open an issue with the output if
something does not work.

## Install

PureMouse requires macOS 14 or later, on Apple silicon or Intel. It is tested on macOS 26 and 27.

### From a release

1. Download `PureMouse-<version>.zip` from the
   [latest release](https://github.com/mblauberg/PureMouse/releases/latest), unzip it, and drag
   `PureMouse.app` to Applications.
2. PureMouse is not notarised by Apple, so macOS blocks it on first launch. Clear the quarantine
   flag **before** opening it:

   ```sh
   xattr -dr com.apple.quarantine /Applications/PureMouse.app
   ```

   Alternatively, open it, dismiss the warning, and choose **Open Anyway** in System Settings ›
   Privacy & Security. Once macOS displays that warning, it continues to block PureMouse until you
   acknowledge it, even if you clear the flag afterwards.
3. Open PureMouse. It adds itself to login items, creates `~/.config/puremouse/config.json` from
   the example if you do not have one, and starts.
4. Grant the two [permissions](#permissions) it asks for.

To update, drag the new `PureMouse.app` over the old one and open it again. To stop PureMouse, turn
it off under System Settings › General › Login Items, or run
`/Applications/PureMouse.app/Contents/MacOS/puremouse unregister`. The `register` command starts it
again.

### From source

With Xcode or its command line tools:

```sh
./scripts/make-cert.sh   # once per Mac: a signing identity, so permissions survive rebuilds
./scripts/install.sh     # build, install /Applications/PureMouse.app and start it
./scripts/uninstall.sh   # stop and remove (keeps your config)
./scripts/package.sh     # release zip for Apple silicon and Intel, in .build/dist/
```

### Permissions

Grant both in **System Settings › Privacy & Security**:

| Permission | Why |
|---|---|
| **Accessibility** | To post scrolls, keystrokes and swipes. Until granted, wheels stay native and actions that post events do nothing |
| **Input Monitoring** | To read the mouse over Bluetooth. A receiver works without it |

Because macOS only applies permission grants to newly started processes, PureMouse periodically
checks in the background and restarts itself once a grant arrives. The log lists any permission
that is missing.

### Logi Options+

Quit Logi Options+ before using PureMouse: only one program can control the buttons at a time.
PureMouse logs an error at startup if it finds Options+ running. To remove Options+ entirely, use
Logitech's uninstaller.

## Configure

The config lives at `~/.config/puremouse/config.json`. Every field is optional, and anything you
leave out retains the mouse's existing settings. Here is a short example
([`config.example.json`](config.example.json) has more):

```json
{
  "dpi": 1600,
  "smoothScroll": { "speed": 0.8 },
  "buttons": {
    "gesture": { "click": "missionControl", "left": "spaceLeft", "right": "spaceRight" },
    "back": "navigateBack",
    "forward": "navigateForward",
    "middle": "toggleScrollMode"
  }
}
```

PureMouse watches the file and applies changes when you save it. A file that does not load is
reported in the log and the previous settings stay in effect. To reload by hand:

```sh
launchctl kill HUP gui/$UID/io.github.mblauberg.puremouse
```

### Fields

| Field | Meaning |
|---|---|
| `dpi` | Sensor resolution, 50–25600. PureMouse uses the nearest value the mouse supports (200–8000 in steps of 50 on the MX Master 3S) and logs when it differs |
| `scrollWheel.inverted` | Invert the main wheel in hardware. With natural scrolling on, `true` gives classic wheel direction and leaves the trackpad alone |
| `scrollWheel.mode` | `"ratchet"` or `"freespin"` on first connect. Later toggles are kept |
| `scrollWheel.smartShiftThreshold` | 1–50 enables SmartShift's automatic free-spin; 255 disables it. Must be 1–255 |
| `thumbWheel.inverted` | Invert the thumb wheel in hardware |
| `buttons` | Button → action or gesture (see below) |
| `smoothScroll` | If present, PureMouse scrolls both wheels itself (see below). If absent, or `enabled` is false, the wheels scroll normally |
| `gesture.distanceMm` | How far the mouse moves before a gesture fires, in millimetres, 0.5–50. Default 4 |
| `gesture.repeatIntervalMs` | Minimum gap between repeated gestures in one hold, 0–5000. Default 400 |

A number outside its range is an error: the config is not loaded (on reload, the previous one stays
in effect) and the log names the field.

### Smooth scrolling

| Field | Default | Range | Meaning |
|---|---|---|---|
| `enabled` | true | | false scrolls natively but keeps the settings below |
| `speed` | 1 | 0.1–10 | Main wheel distance; 1 is about 40 px per notch when scrolling slowly |
| `horizontalSpeed` | 1 | 0.1–10 | Thumb wheel distance; 1 is about 360 px per turn when scrolling slowly |
| `acceleration` | 1 | 0–10 | Extra distance when scrolling fast (1.5× at 5 notches/s, 3× at 17, up to 8×); 0 is linear |
| `smoothingMs` | 125 | 0–2000 | How long the glide lasts. Most of each movement finishes within about 100 ms anyway, so longer values give a softer landing rather than lag. 0 scrolls immediately |
| `shiftScrollsHorizontally` | true | | Shift + wheel scrolls sideways |

PureMouse posts plain continuous pixel scrolls without trackpad gesture phases, which would
otherwise make browsers swipe back and forward. `scrollWheel.inverted` and `thumbWheel.inverted`
maintain their behaviour relative to the system's natural-scrolling setting.

### Buttons, actions and gestures

**Buttons:** `gesture` (thumb), `back`, `forward`, `top` (behind the wheel), `middle` (wheel
press), or any hex control ID such as `"0x00c4"`. Run `puremouse probe` to list a mouse's
controls.

**Actions:** `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`, `spaceRight`,
`navigateBack`, `navigateForward`, `toggleScrollMode`, `none`, `{"keys": "cmd+shift+4"}`,
`{"run": "open -a Safari"}`.

**Gestures:** an object with any of `click`, `up`, `down`, `left` and `right`, each an action.
While a gesture button is held, the pointer stays still.

### System Settings

- **Natural scrolling** applies as usual; PureMouse reads it at the start of each scroll.
- **Scrolling speed** no longer affects the mouse once `smoothScroll` is on; use `speed` and
  `acceleration` instead. Other mice are unaffected.
- **Tracking speed** and pointer acceleration still apply on top of `dpi`.
- **Swipe between pages**, Mission Control and the "Move left/right a space" keyboard shortcuts
  must stay enabled for the back/forward and Spaces actions.

## Troubleshooting

- **Logs** are in `~/Library/Logs/PureMouse.log`. For button-level detail, stop the agent with
  `puremouse unregister`, run `puremouse --verbose run` in a terminal, then start the agent again
  with `puremouse register`. (Inside the app, the command is
  `/Applications/PureMouse.app/Contents/MacOS/puremouse`.)
- **Wheels remain native and buttons do nothing:** check the log for a missing permission.
  PureMouse restarts itself once it is granted;
  `launchctl kickstart -k gui/$UID/io.github.mblauberg.puremouse` forces a restart.
- **Buttons or wheels misbehave, or settings do not persist:** check the log for "Logi Options+ is
  running". The two fight over the mouse; quit Options+ or uninstall it.
- **Wheels unresponsive after a crash:** if PureMouse is killed outright it cannot restore the
  mouse, so with `smoothScroll` the wheels stay silent until it restarts a few seconds later.
  Turning the mouse off and on also resets it.
- **Inspecting a mouse:** `puremouse probe` lists every HID++ device with its features and current
  settings. It only reads, so it is safe to run at any time.

### After a macOS upgrade

A few actions rely on undocumented macOS interfaces, which a major release can change without
notice. The first line of the log on each start shows the macOS version. To check every action,
press each button, or run `puremouse action <name>` from a terminal that has Accessibility.

| Interface | Used by | If it stops working, bind instead |
|---|---|---|
| Dock notifications | `missionControl`, `appExpose`, `showDesktop`, `launchpad` | `{"keys": "ctrl+up"}`, `{"keys": "ctrl+down"}`, `{"keys": "f11"}` (the default shortcuts) |
| Navigation-swipe event fields | `navigateBack`, `navigateForward` | `{"keys": "cmd+["}`, `{"keys": "cmd+]"}` (most apps) |
| `CVDisplayLink` (deprecated since macOS 15) | Smooth-scroll frame timing | Nothing: scrolling continues, unsmoothed |

macOS 27 stopped honouring the event fields for three-finger Dock swipes. PureMouse does not use
them, and navigation swipes still work on macOS 27.

## How it works

PureMouse discovers Logitech receivers and Bluetooth mice through IOKit, speaks HID++ 2.0 to them,
and diverts the buttons and wheels you configure so their events come to PureMouse instead of
macOS. It then posts the matching system events. It is a single Swift binary with no
dependencies, run by launchd from a login agent that it installs itself.

```
Sources/HIDPP/       protocol only: framing, IOKit transport, request/response handling,
                     typed feature wrappers
Sources/PureMouseKit/ shared with the menu bar app: config model and decoder, status/control
                     channel (docs/companion.md)
Sources/puremouse/   policy: applying config, actions, gestures, smooth scrolling, one session
                     per mouse, the daemon (discovery, reconnects, wake, reload, permissions, quit)
Tests/               pure logic: framing and event parsing, config, gestures, scroll maths
scripts/             build, install, uninstall, package, signing identity, icon
assets/              app icon (Icon Composer source, compiled icon, README images), menu bar glyph
```

## Development

```sh
swift build && swift test
.build/debug/puremouse probe                                     # read-only; safe with the agent
/Applications/PureMouse.app/Contents/MacOS/puremouse unregister  # stop the installed agent first
.build/debug/puremouse --verbose run ./config.example.json       # then run a dev build
./scripts/install.sh                                             # reinstall and restart the agent
```

A build run from a terminal uses the terminal's permissions, not the app's. Design invariants,
pitfalls and instructions for adding actions or device features are in [`AGENTS.md`](AGENTS.md).

Builds are signed with the code-signing identity named `PureMouse` when the keychain has one
(`PUREMOUSE_SIGN_IDENTITY` picks another). Because macOS ties permission grants to the signature,
an ad-hoc build needs them granted again after every install, and releases must all be signed with
the same identity.

## Protocol references

Logitech does not publish HID++ 2.0, so the feature layouts here were checked against the open
implementations in [Solaar](https://github.com/pwr-Solaar/Solaar) and
[logiops](https://github.com/PixlOne/logiops).

## Licence

MIT. See [`LICENSE`](LICENSE).

PureMouse is an independent project, not affiliated with or endorsed by Logitech. Logitech, Logi,
Logi Options+ and MX Master are trademarks of Logitech.

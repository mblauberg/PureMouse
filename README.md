# mxd

A tiny, offline replacement for Logi Options+ on macOS, built for the MX Master 3S. It talks to
the mouse directly over Logitech's HID++ 2.0 protocol, through the Bolt receiver or Bluetooth,
and turns its buttons into system actions. It can also do smooth scrolling itself, replacing
[Mos](https://mos.caldis.me). No UI, no network access, no account, about 3 MB of memory.

## What it does

- Diverts chosen buttons to itself and maps them to actions: Mission Control, App Exposé, Show
  Desktop, switching Spaces, back/forward (as trackpad swipes), any keystroke, or a shell command.
- Turns a hold of the thumb button plus mouse movement into a four-way gesture.
- Sets DPI, scroll-wheel direction (in hardware), thumb-wheel direction, and the ratchet/free-spin
  mode, with a button to toggle the mode.
- Optionally takes over both wheels for smooth, accelerated pixel scrolling (`smoothScroll`).
- Re-applies all of this whenever the mouse wakes, reconnects or switches between the receiver
  and Bluetooth, and after the Mac wakes. The mouse forgets these settings on every reconnect.
- On quit (SIGTERM/SIGINT, including `mxd unregister` and logout) it hands the mouse back in
  its native state. Nothing is stored on the mouse or receiver, so they behave normally on a
  computer without mxd.

## Install

mxd needs macOS 14 or later, on Apple silicon or Intel.

**From a release zip.** Unzip it and drag `mxd.app` to Applications. mxd is not notarised by
Apple, so macOS refuses the first launch: either clear the download flag in Terminal **before**
opening it,

```sh
xattr -dr com.apple.quarantine /Applications/mxd.app
```

or open it, dismiss the warning, and choose **Open Anyway** in System Settings › Privacy &
Security. Then open mxd. It registers itself to start at login (it appears under System Settings ›
General › Login Items, where you can switch it off), creates `~/.config/mxd/config.json` from the
example if you have none, and starts.

**From source**, with Xcode or its command line tools:

```sh
./scripts/make-cert.sh        # once per Mac: a signing identity, so permissions survive rebuilds
./scripts/install.sh          # build, install /Applications/mxd.app, start it at login
./scripts/uninstall.sh        # stop and remove (keeps your config)
./scripts/package.sh          # release zip for Apple silicon and Intel, in .build/dist/
```

launchd starts mxd at login and restarts it within seconds if it ever exits. To update, replace
`mxd.app` and open it again (or re-run the install script), which restarts it. By hand,
`/Applications/mxd.app/Contents/MacOS/mxd register` starts or restarts the installed copy, and
`unregister` stops it and removes it from login items until the next `register`.

The first run asks for two permissions. Grant both in **System Settings › Privacy & Security**:

- **Accessibility**, to post scrolls, keystrokes and swipes. Until it is granted, the wheels stay
  native and actions that post events (back/forward, Spaces, keystrokes) do nothing.
- **Input Monitoring**, to read the mouse over Bluetooth (the Bolt receiver works without it).

macOS only applies a grant to a newly started process, so mxd checks every so often and
restarts itself when one arrives. The log says which permissions are missing.

macOS ties these grants to the app's signature, so they survive an update only when it is signed
by the same identity. The build signs with the code-signing identity named `mxd` when the keychain
has one (`scripts/make-cert.sh` creates a self-signed one; `MXD_SIGN_IDENTITY` picks another name).
Otherwise it signs ad hoc and the grants must be given again after every install. Releases must
all be signed with one identity: keep a backup of it.

Quit Logi Options+ first: only one program can control the buttons at a time. To remove it
entirely, use Logitech's uninstaller.

## Configure

Config lives at `~/.config/mxd/config.json`; `config.example.json` is a full example. Every field
is optional, and anything you leave out stays as the device has it. Reload without restarting:

```sh
launchctl kill HUP gui/$UID/local.mxd
```

| Field | Meaning |
|---|---|
| `dpi` | Sensor resolution, 200–8000 in steps of 50 |
| `scrollWheel.inverted` | Invert the main wheel in hardware. With natural scrolling on, `true` gives classic wheel direction and leaves the trackpad alone |
| `scrollWheel.mode` | `"ratchet"` or `"freespin"` on first connect. Later toggles are kept |
| `scrollWheel.smartShiftThreshold` | 1–50 enables SmartShift's automatic free-spin; 255 disables it |
| `thumbWheel.inverted` | Invert the thumb wheel in hardware |
| `buttons` | Button → action or gesture (below) |
| `smoothScroll` | Present: mxd scrolls both wheels itself (below). Absent: the wheels report as ordinary scrolling |
| `gesture.distanceMm` | Mouse travel before a gesture direction fires, in millimetres. Default 4 |
| `gesture.repeatIntervalMs` | Minimum gap between repeated directions in one hold. Default 400 |

**Smooth scrolling:** `smoothScroll` takes these optional fields:

| Field | Default | Meaning |
|---|---|---|
| `speed` | 1 | Main wheel distance; 1 is about 40 px per notch when scrolling slowly |
| `horizontalSpeed` | 1 | Thumb wheel distance; 1 is about 360 px per turn when slow |
| `acceleration` | 1 | Extra distance when scrolling quickly (1.5× at 5 notches/s, 3× at 17, capped at 8×); 0 is linear |
| `smoothingMs` | 125 | How long the momentum glide lasts. Most of each movement lands within about 100 ms regardless, so longer values add a softer landing rather than lag. 0 posts movement immediately |
| `shiftScrollsHorizontally` | true | Shift + wheel scrolls sideways |

It posts plain continuous pixel scrolls (like Mos, without trackpad gesture phases, which make
browsers swipe back and forward), timed to the display's refresh. `scrollWheel.inverted` and
`thumbWheel.inverted` keep their meaning, relative to the system's natural-scrolling setting.

**Buttons:** `gesture` (thumb), `back`, `forward`, `top` (behind the wheel), `middle` (wheel
press), or any hex control ID such as `"0x00c4"`. Run `mxd probe` to list a device's controls.

**Actions:** `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`,
`spaceRight`, `navigateBack`, `navigateForward`, `toggleScrollMode`, `none`,
`{"keys": "cmd+shift+4"}`, `{"run": "open -a Safari"}`.

**Gestures:** an object with any of `click`, `up`, `down`, `left`, `right`, each an action. A
button bound to a gesture captures mouse movement while it is held, so the pointer stays still.

`spaceLeft` and `spaceRight` send ctrl+←/→, so the "Move left/right a space" shortcuts must stay
enabled in Keyboard settings.

## System Settings

- **Natural scrolling** applies as usual: mxd reads it at the start of each scroll.
- **Scrolling speed** (Mouse) stops affecting the MX wheels once `smoothScroll` is on, because mxd
  generates the scroll events; use `speed` and `acceleration` instead. Other mice are unaffected.
- **Tracking speed** and pointer acceleration still apply on top of `dpi`.
- **Swipe between pages** and the Mission Control/Spaces shortcuts must stay enabled for the
  back/forward and Spaces actions.

## Troubleshooting

- Log: `~/Library/Logs/mxd.log`. For button-level detail, stop the agent with
  `/Applications/mxd.app/Contents/MacOS/mxd unregister`, run `mxd --verbose run` in a terminal,
  and afterwards start the agent again with `register`.
- `mxd probe` shows every HID++ device, its features and current settings. It only reads, so
  it is safe to run alongside anything else.
- Wheels native and buttons dead: check the log for a missing permission. After granting it,
  mxd restarts itself; `launchctl kickstart -k gui/$UID/local.mxd` forces a restart.
- If mxd is killed outright (`kill -9`, a crash) it cannot restore the mouse, so with
  `smoothScroll` the wheels stay silent until launchd restarts it a few seconds later. Turning the
  mouse off and on also resets it to factory behaviour.

## After a macOS upgrade

A few actions rely on undocumented macOS interfaces, which a major release can change without
notice. The log's first line on each start (`mxd <version> on macOS <version>`) shows which
release a log comes from. To check every action, press each button, or run
`/Applications/mxd.app/Contents/MacOS/mxd action <name>` from a terminal that has Accessibility.

| Interface | Used by | If it stops working, bind instead |
|---|---|---|
| Dock notifications (`CoreDockSendNotification`) | `missionControl`, `appExpose`, `showDesktop`, `launchpad` | `{"keys": "ctrl+up"}`, `{"keys": "ctrl+down"}`, `{"keys": "f11"}` (the default shortcuts) |
| Navigation-swipe event fields | `navigateBack`, `navigateForward` | `{"keys": "cmd+["}`, `{"keys": "cmd+]"}` (most apps, not all) |
| `CVDisplayLink` (deprecated since macOS 15) | smooth-scroll frame clock | nothing: scrolling continues unsmoothed |

macOS 27 stopped reading the event fields for three-finger dock swipes (Mac Mouse Fix 3.1.0 had
to switch to attached IOHIDEvents). mxd doesn't post dock swipes, and navigation swipes were not
reported broken on 27.0 (Mac Mouse Fix left them unchanged), so mxd should need no change for it.
A later release could drop navigation swipes the same way; the fallback above covers that.

## Layout

```
Sources/HIDPP/   protocol only: framing (Report), IOKit transport (HIDInterface/HIDMonitor),
                 request/response handling (HIDPPDevice), typed feature wrappers (Features)
Sources/mxd/     policy: Config, Action/Keystroke/NavigationSwipe, GestureRecognizer,
                 ScrollEngine/ScrollModel (smooth scrolling), Session (one per mouse),
                 Daemon (discovery, reconnect, wake, reload, permissions, quit), Probe
Tests/           pure logic: framing and event parsing, config, gestures, scroll maths
scripts/         build-app.sh (bundle, embedded login agent, signing), install.sh, uninstall.sh,
                 package.sh (universal release zip), make-cert.sh (self-signed identity)
```

How to extend it (actions, device features, per-app scrolling) is in `AGENTS.md`. Protocol
details come from Solaar, logiops and Mac Mouse Fix.

## Development

```sh
swift build && swift test
.build/debug/mxd probe                                  # read-only; safe alongside the agent
/Applications/mxd.app/Contents/MacOS/mxd unregister    # stop the installed agent first
.build/debug/mxd --verbose run ./config.example.json    # then run a dev build in the foreground
./scripts/install.sh                                    # reinstall and restart the agent
```

A terminal-launched build uses the terminal's permissions, not the app's. See `AGENTS.md` for
design invariants and the things that are easy to break.

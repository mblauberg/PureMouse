<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/AppIcon-dark.png">
    <img src="assets/AppIcon.png" width="128" height="128" alt="PureMouse icon">
  </picture>
</p>

<h1 align="center">PureMouse</h1>

<p align="center">
  A lightweight, native alternative to Logi Options+ for Logitech mice on macOS, developed with the MX Master 3S.<br>
  Buttons, gestures, smooth scrolling, DPI and per-app settings, in about 5 MB of memory (about 20 MB with the menu bar app).
</p>

<p align="center">
  <a href="https://github.com/mblauberg/PureMouse/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mblauberg/PureMouse?color=0A84FF"></a>
  <a href="https://github.com/mblauberg/PureMouse/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mblauberg/PureMouse/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-universal-555555">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/github/license/mblauberg/PureMouse?color=2EA44F"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-dark.png">
    <img src="docs/images/menu-light.png" alt="The PureMouse menu: mouse, battery, smooth scrolling, pointer speed and pause">
  </picture>
</p>

PureMouse talks to the mouse directly over Logitech's HID++ protocol: no account, no cloud sync and
no updater in the background. It is written in Swift with no third-party dependencies, and when
the mouse is idle, so is PureMouse.

## Lightweight by design

| | PureMouse (main), as measured |
|---|---|
| Download | 4.6 MB dmg, 11.9 MB installed; universal (Apple silicon and Intel) |
| Memory | Background process: 4-6 MB. Menu bar app: about 9 MB fresh, about 14 MB once its menu has been opened. Settings: about 36 MB in its own process while its window is open, then nothing (medians of 5 on macOS 27.0.1) |
| Idle CPU | Zero in normal use: no polling, no timers, no wake-ups* |
| Processes | Two: the background process and an optional menu bar app, plus Settings while its window is open |
| Network | None, unless you press **Check for Updates** |
| Privacy | No account, no telemetry, nothing stored on the mouse |

The background process uses only system frameworks and no UI toolkit. Settings is a separate app
that runs only while its window is open (it shows in the Dock meanwhile, and quits when you close
it), so the menu bar app stays small. Smooth scrolling runs in step with the display, and only
while the wheel is moving.

<sub>* Two exceptions, both short-lived: while a permission is still to be granted, PureMouse checks
for it with growing gaps for up to ten minutes; and a Bluetooth mouse that does not answer when it
connects is retried once a minute until it does.</sub>

## Features

**Buttons and gestures**
- Map any button to Mission Control, App Exposé, Show Desktop, Launchpad, Spaces, back and
  forward, volume, brightness, tabs, zoom, a keyboard shortcut or a shell command.
- Hold the gesture button and move the mouse for four more actions.
- **Find by Pressing…** finds a button by pressing it.

**Scrolling**
- Smooth, accelerated scrolling on both wheels, with Precise, Balanced and Gliding presets or
  your own feel.
- The thumb wheel scrolls sideways, or switches tabs, changes the volume, zooms, moves between
  Spaces or runs two actions of your choice, in whichever direction you prefer.
- Wheel direction, ratchet or free spin, and SmartShift.

**Per app**
- Give an app its own buttons, thumb wheel and scrolling. Buttons follow the app you're using;
  scrolling and the thumb wheel follow the app under the pointer.
- Suggestions for common apps: tab switching in browsers, volume in Zoom and Teams, zoom in Word,
  PowerPoint and Preview.

**Everything else**
- DPI with presets you can cycle from a button or the menu.
- Battery level in the menu, with a notification at 20% and 5%. It follows each mouse across
  reconnects, warns once if a mouse it recognises comes back already low, and goes away when the
  mouse is charging or back at 25%. It needs the menu bar icon shown.
- **Open at login** is a switch of its own in Settings › General, apart from whether PureMouse
  is running: **Stop** returns the mouse to normal and leaves login as it is.
- **Universal Control:** when the pointer moves to another Mac, the wheels and buttons carry on
  working there.
- **Check for Updates** in Settings › About, only when you ask.
- Settings return after every reconnect and wake. Quitting hands the mouse straight back to
  macOS, and nothing is written to the mouse, so it behaves normally on any other computer.

## Settings

The menu bar shows the mouse and its battery, and switches smooth scrolling, pointer speed and
pause. **Settings…** covers everything else, and changes apply as you make them. Opening
PureMouse from Applications opens Settings too, even with the menu bar icon hidden.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-buttons-dark.png">
    <img src="docs/images/settings-buttons-light.png" width="400" align="top" alt="Buttons settings: an action for each button and gesture">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-app-dark.png">
    <img src="docs/images/settings-app-light.png" width="400" align="top" alt="Google Chrome's own settings: Command-T on the top button and the thumb wheel switching tabs">
  </picture>
</p>

<details>
<summary>More settings: scrolling, general, apps, pointer and about</summary>
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-scrolling-dark.png">
    <img src="docs/images/settings-scrolling-light.png" width="400" align="top" alt="Scrolling settings: smooth scrolling feel and speed, main wheel direction and mode, thumb wheel switching tabs with its direction">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-general-dark.png">
    <img src="docs/images/settings-general-light.png" width="400" align="top" alt="General settings: open at login, whether PureMouse is running, menu bar icon, low battery notification, Universal Control, permissions and files">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-apps-dark.png">
    <img src="docs/images/settings-apps-light.png" width="400" align="top" alt="Apps settings: Chrome, Teams, Word, Preview and Safari, each with its own thumb wheel and buttons">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-pointer-dark.png">
    <img src="docs/images/settings-pointer-light.png" width="400" align="top" alt="Pointer settings: resolution and DPI presets">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-about-dark.png">
    <img src="docs/images/settings-about-light.png" width="400" align="top" alt="About settings: version, links, Check for Updates and a Support PureMouse link">
  </picture>
</p>
</details>

Prefer a text file? Everything is also in `~/.config/puremouse/config.json`, which applies as soon
as you save it, and which can give each model of mouse its own settings; see
[Configuration](docs/configuration.md).

## Supported mice

PureMouse is developed and tested with the **MX Master 3S**. Rather than relying on a fixed list
of models, it adopts a device that says it is a mouse or trackball, or that has adjustable DPI,
and turns on each feature that mouse reports over HID++. Keyboards, numpads, presenters and
receivers are left alone. Only the MX Master 3S has been tested on a real mouse; the others are
untested:

| Mouse | What PureMouse uses | Tested |
|---|---|---|
| MX Master 3S | Buttons, gestures, DPI, both wheels, SmartShift and battery | Yes |
| MX Master 3 / 3 for Business | The same, including older firmware's battery reporting | Untested |
| MX Master 4 | The same, plus haptic feedback as an action | Untested |
| MX Anywhere 3 / 3S | Buttons, DPI, smooth scrolling, SmartShift and battery | Untested |
| MX Vertical / Lift | Buttons, DPI and battery | Untested |
| Signature Plus M750 | Buttons, DPI, smooth scrolling on its notched wheel and battery | Untested |
| MX Ergo | Buttons, smooth scrolling on its notched wheel and battery; no DPI control | Untested |
| G305 and other G-series mice in onboard mode | Battery and, where the mouse accepts it, DPI; in onboard mode DPI cannot be set and the status says so | Untested |
| G Pro X 2 Superstrike | DPI and battery | Untested |

The untested rows are what each mouse reports, not what PureMouse has done on it: they come from
`puremouse probe` captures and device listings kept as test fixtures (the MX Master 4 and MX Ergo
from raw captures, the M750 from a user's probe, the G305 and Superstrike from Solaar's listings),
and from the families' usual features for the rest. PureMouse never writes the settings a mouse
keeps through a power cycle, such as onboard profiles, which is why a G305 in onboard mode does
not get DPI control. A mouse that reports only a battery level shows that level, not a percentage.

Bluetooth and Logi Bolt or Unifying receivers are picked up automatically. Using a different
Logitech mouse? Attaching [`puremouse probe` output](docs/troubleshooting.md#inspecting-a-mouse)
to an issue is the quickest way to get it supported.

## Install

Requires macOS 14 or later.

1. Download `PureMouse-<version>.dmg` from the
   [latest release](https://github.com/mblauberg/PureMouse/releases/latest), open it and drag
   `PureMouse.app` to Applications.
2. PureMouse is signed but not notarised, so macOS blocks its first launch. Clear the quarantine
   flag **before** opening it (or see [Opening a blocked app](docs/troubleshooting.md#opening-a-blocked-app)):

   ```sh
   xattr -dr com.apple.quarantine /Applications/PureMouse.app
   ```

3. Quit Logi Options+ if it is installed: only one app can control the mouse at a time.
4. Open PureMouse. It opens Settings and starts at login from then on.
5. In System Settings › Privacy & Security, allow **Accessibility** (for scrolling, shortcuts and
   swipes) and **Input Monitoring** (for Bluetooth). PureMouse picks up each grant by itself, and
   Settings › General shows both. [Privacy](docs/privacy.md) says what each one is used for.

**Updating:** download the new version, replace the app and open it; it replaces the running
copy. Your settings and permissions carry over.

**Removing:** run the command below, then move the app to the Bin. Your config stays in
`~/.config/puremouse`.

```sh
/Applications/PureMouse.app/Contents/MacOS/puremouse unregister
```

## Privacy and security

No account and no telemetry. PureMouse writes only to your home folder and goes online only when
you press **Check for Updates**. [Privacy](docs/privacy.md) lists every permission, file and
request; [Security](SECURITY.md) says how to report a vulnerability.

## Documentation

- [Configuration](docs/configuration.md): every field, action and gesture
- [Troubleshooting](docs/troubleshooting.md): logs, permissions, Gatekeeper, macOS upgrades
- [How it works](docs/how-it-works.md): the background process, menu bar app and Settings,
  device support, scrolling, source layout
- [Architecture decisions](docs/adr/README.md): why it is built this way
- [Development](docs/development.md): building, testing, signing and releases
- [Privacy](docs/privacy.md): permissions, files written and the one network request

Bug reports and ideas are welcome in [Issues](https://github.com/mblauberg/PureMouse/issues);
[Contributing](CONTRIBUTING.md) explains how to ask for a mouse and how to send a change.

## Support

PureMouse is free and open source. If it's made your mouse nicer to use, you can support it on [GitHub Sponsors](https://github.com/sponsors/mblauberg). Thank you!

## Licence

MIT. See [`LICENSE`](LICENSE).

PureMouse is an independent project, not affiliated with or endorsed by Logitech. Logitech, Logi,
Logi Options+, Logi Bolt, Unifying and MX Master are trademarks of Logitech.

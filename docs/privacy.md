# Privacy

PureMouse has no account and no telemetry, sends nothing about you anywhere, and stores nothing on
the mouse. It makes one network request, and only when you press **Check for Updates**. This page
lists what it is allowed to do, every file it writes and that one request, each with the source
file that shows it.

## Permissions

PureMouse asks for two permissions, for the background process only (`puremouse`), when it starts
without them. Source:
[`Sources/puremouse/Permissions.swift`](../Sources/puremouse/Permissions.swift).

| Permission | What PureMouse does with it | What it never does |
|---|---|---|
| **Accessibility** (posting events, `CGRequestPostEventAccess`) | Posts the scrolls, keystrokes, swipes and clicks your buttons and wheels are set to | Read the screen or other apps' contents, or control their windows |
| **Input Monitoring** (`IOHIDRequestAccess`, listen) | Reads HID++ reports from a Logitech mouse over Bluetooth, and lets macOS open a receiver if it refuses otherwise. A receiver normally works without it | Record what you type, or open devices from other makers. Mouse buttons reach the log only as [the log row below](#files-it-writes) says |

PureMouse opens Logitech receivers and Logitech Bluetooth devices only, and uses only their HID++
reports ([`Sources/HIDPP/HIDInterface.swift`](../Sources/HIDPP/HIDInterface.swift),
[`Sources/HIDPP/Report.swift`](../Sources/HIDPP/Report.swift)). macOS matches Bluetooth devices
by maker, so the reports of another Logitech Bluetooth device, such as a keyboard's keystrokes,
also reach the background process, which discards them unread
([ADR 6](adr/0006-ble-input-value-matching.md) plans to stop that).

Without Accessibility the wheels stay native and buttons set to actions do nothing; DPI and
SmartShift settings still apply. [Troubleshooting](troubleshooting.md#permissions) covers granting
permissions.

The menu bar app needs neither permission. It asks to show notifications the first time it has a
low-battery warning to show, or when you turn the warning on
([`Sources/PureMouseMenu/Model/Notifier.swift`](../Sources/PureMouseMenu/Model/Notifier.swift)).

## What it reads on this Mac

- **Which app is in front, or under the pointer**, by bundle ID, at the moment a button or wheel
  you set per app is used ([`Sources/puremouse/ForegroundApp.swift`](../Sources/puremouse/ForegroundApp.swift)).
  It is kept only in memory, except that with `--verbose` the log names it (see the log below).
- **The names of your running processes**, at start, to warn when Logi Options+ is running ([`Sources/puremouse/LogiOptions.swift`](../Sources/puremouse/LogiOptions.swift)).
- **Your natural-scrolling setting** and **your Spaces shortcuts**, so synthetic scrolls and the
  `spaceLeft`/`spaceRight` actions match them
  ([`Sources/puremouse/ScrollEngine.swift`](../Sources/puremouse/ScrollEngine.swift),
  [`Sources/puremouse/SystemKeys.swift`](../Sources/puremouse/SystemKeys.swift)).
- **Whether Universal Control has the pointer on another Mac**, from a system notification
  ([`Sources/puremouse/UniversalControl.swift`](../Sources/puremouse/UniversalControl.swift)).

## Files it writes

All of them are in your home folder.

While it runs, the background process changes settings on the mouse that it forgets when it
reconnects: which buttons it sends to PureMouse, how the wheels report, DPI and SmartShift. When it
quits or pauses it hands the buttons and wheels back; DPI and SmartShift stay as set until the mouse
reconnects. It stores nothing on the mouse or the receiver.

| File | Written by | What it holds |
|---|---|---|
| `~/.config/puremouse/config.json` | Settings, when you change something ([`Sources/PureMouseMenu/Logic/ConfigFile.swift`](../Sources/PureMouseMenu/Logic/ConfigFile.swift)); a copy of the example config on first open if there is none ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Your settings. A symlinked config has its target replaced, not the link |
| `~/Library/Logs/PureMouse.log`, and `PureMouse.log.1` once it passes 1 MiB | The background process ([`Sources/puremouse/Log.swift`](../Sources/puremouse/Log.swift)) | Always: a start line with the PureMouse and macOS versions; each mouse and receiver by the name macOS reports (for Bluetooth, the name in Bluetooth settings) and product ID, with its features; permission state; config errors; Logi Options+ running; Universal Control, pause and wake events; and a failed `run` command's first 80 characters with its exit status. While you use **Select by Pressing**: the control ID of the button you press. With `--verbose` only: the control ID of every press, gesture directions, and the bundle ID of the app whose settings apply. Never what you type, and never a `run` command's output |
| `~/Library/LaunchAgents/io.github.mblauberg.puremouse.plist` and `….menu.plist` | `puremouse register`, which opening the app runs ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Start-at-login entries naming the app's two programs. `puremouse unregister` removes them |
| `~/Library/Application Support/PureMouse/launchd/<label>.plist` | `puremouse start`, for a job that is not registered ([`Sources/puremouse/LoginService.swift`](../Sources/puremouse/LoginService.swift)) | The same entry as the one in `LaunchAgents`, outside the folder launchd loads at login, so it runs now and not at the next login. `puremouse stop` removes it |
| `~/Library/Application Support/PureMouse/status.json` | The background process ([`Sources/puremouse/Channel.swift`](../Sources/puremouse/Channel.swift)) | What the menu shows: connected mice, battery, DPI, permission and config state |
| `~/Library/Application Support/PureMouse/control.json` | The menu bar app ([`Sources/PureMouseMenu/Model/AppModel.swift`](../Sources/PureMouseMenu/Model/AppModel.swift)) | Requests to the background process: pause, select by pressing, use the configured DPI. Removed when the background process starts ([`Sources/puremouse/Channel.swift`](../Sources/puremouse/Channel.swift)) |
| `~/Library/Application Support/PureMouse/battery-alerts.json` | The menu bar app ([`Sources/PureMouseMenu/Logic/BatteryAlert.swift`](../Sources/PureMouseMenu/Logic/BatteryAlert.swift)) | Which low-battery warning was last shown per mouse, so it is not repeated |
| `~/Library/Application Support/PureMouse/menu-hidden` | `puremouse menu off` ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Empty; its presence keeps the menu bar icon hidden |
| `~/Library/Application Support/PureMouse/show-settings` | Opening the app ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift), [`Sources/PureMouseMenu/AppController.swift`](../Sources/PureMouseMenu/AppController.swift)) | Empty; asks the menu bar app to open Settings, and is removed once seen |
| `~/Library/Preferences/io.github.mblauberg.puremouse.menu.plist` | macOS, for the menu bar app ([`Sources/PureMouseMenu/Settings/SettingsWindow.swift`](../Sources/PureMouseMenu/Settings/SettingsWindow.swift)) | The Settings window's position and its last pane |

The file and channel formats are in [Configuration](configuration.md) and
[Companion](companion.md). The low-battery warning is a local notification
([`Sources/PureMouseMenu/Model/Notifier.swift`](../Sources/PureMouseMenu/Model/Notifier.swift)).

## The one network request

Pressing **Check for Updates** in Settings › About makes one HTTPS GET of
`https://api.github.com/repos/mblauberg/PureMouse/releases/latest` and compares the version it
returns with yours ([`Sources/PureMouseMenu/Logic/UpdateCheck.swift`](../Sources/PureMouseMenu/Logic/UpdateCheck.swift)).
It uses an ephemeral session, so no cookies or cache are kept. GitHub sees what any web request
shows: your IP address and a standard user agent naming the app and the system version. There are
no background checks, and the background process has no network code at all.

Buttons such as **View Release** and **How to Remove** open a GitHub page in your browser.

## Commands you set up

A `run` action executes the command you wrote in your config with `/bin/sh`, as you
([`Sources/puremouse/Action.swift`](../Sources/puremouse/Action.swift)). PureMouse adds none of its own.
Its output is discarded; if it fails, the log keeps its first 80 characters and its exit status.

## What `puremouse probe` prints

`puremouse probe` only reads, and prints for each Logitech HID++ interface
([`Sources/puremouse/Probe.swift`](../Sources/puremouse/Probe.swift)):

- the interface's name as macOS reports it (for a Bluetooth mouse, the name it has in Bluetooth
  settings, which you may have changed), its product ID, usage page and connection type;
- for each device: its HID++ version, its model name, its product IDs per connection type, its
  feature table, its controls, and its SmartShift, DPI, wheel, battery and haptic replies.

It does not print a serial number or a Bluetooth address. Feature 0x0003, which the probe uses for
the product IDs, also returns a unit identifier; the probe discards it
([`Sources/HIDPP/Features.swift`](../Sources/HIDPP/Features.swift), `DeviceIdentity`). Read the
output before you paste it into an issue.

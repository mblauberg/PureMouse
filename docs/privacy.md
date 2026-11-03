# Privacy

PureMouse has no account and no telemetry, sends nothing about you anywhere, and stores nothing on
the mouse. Its only network requests are the check for a new release (when you press **Check for Updates**,
and once a day if you allow it) and, when you choose **Update to X.Y.Z…**, the download of that
release. This page lists what it is allowed to do, every file it writes and those requests, each
with the source file that shows it.

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
low-battery warning or an update reminder to show, or when you turn the low-battery warning on
([`Sources/PureMouseMenu/Model/Notifier.swift`](../Sources/PureMouseMenu/Model/Notifier.swift)).
The Settings helper needs no permissions either.

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
| `~/.config/puremouse/config.json` | Settings, when you change something ([`Sources/PureMouseAppSupport/ConfigFile.swift`](../Sources/PureMouseAppSupport/ConfigFile.swift)); a copy of the example config on first open if there is none ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Your settings. A symlinked config has its target replaced, not the link |
| `~/Library/Logs/PureMouse.log`, and `PureMouse.log.1` once it passes 1 MiB | The background process ([`Sources/puremouse/Log.swift`](../Sources/puremouse/Log.swift)) | Always: a start line with the PureMouse and macOS versions; each mouse and receiver by the name macOS reports (for Bluetooth, the name in Bluetooth settings), product ID and device key (its model ID, [Configuration](configuration.md#per-device-settings)), with its features; permission state; config errors; Logi Options+ running; Universal Control, pause and wake events; and a failed `run` command's first 80 characters with its exit status. While you use **Find by Pressing…**: the control ID of the button you press. With `--verbose` only: the control ID of every press, gesture directions, and the bundle ID of the app whose settings apply. Never what you type, and never a `run` command's output |
| `~/Library/LaunchAgents/io.github.mblauberg.puremouse.plist` and `….menu.plist` | `puremouse register`, which opening the app runs ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Start-at-login entries naming the app's two programs. `puremouse unregister` removes them |
| `~/Library/Application Support/PureMouse/launchd/<label>.plist` | `puremouse start`, for a job that is not registered ([`Sources/puremouse/LoginService.swift`](../Sources/puremouse/LoginService.swift)) | The same entry as the one in `LaunchAgents`, outside the folder launchd loads at login, so it runs now and not at the next login. `puremouse stop` removes it |
| `~/Library/Application Support/PureMouse/status.json` | The background process ([`Sources/puremouse/Channel.swift`](../Sources/puremouse/Channel.swift)) | What the menu shows: connected mice (each with its device key, kind, what it supports and the unit ID it reports, a number that identifies that one mouse), battery, DPI, permission and config state |
| `~/Library/Application Support/PureMouse/control.json` | The menu bar app and Settings ([`Sources/PureMouseAppSupport/AppModel.swift`](../Sources/PureMouseAppSupport/AppModel.swift)) | Requests to the background process: pause, select by pressing, use the configured DPI. Removed when the background process starts ([`Sources/puremouse/Channel.swift`](../Sources/puremouse/Channel.swift)) |
| `~/Library/Application Support/PureMouse/battery-alerts.json` | The menu bar app ([`Sources/PureMouseAppSupport/BatteryAlert.swift`](../Sources/PureMouseAppSupport/BatteryAlert.swift)) | Which low-battery warning was last shown per mouse (a mouse that reports its unit ID is listed by its device key and that unit ID), so it is not repeated and can be taken down later |
| `~/Library/Application Support/PureMouse/menu-hidden` | `puremouse menu off` ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift)) | Empty; its presence keeps the menu bar icon hidden |
| `~/Library/Application Support/PureMouse/show-settings` | Opening the app or Settings ([`Sources/puremouse/LoginItem.swift`](../Sources/puremouse/LoginItem.swift), [`Sources/PureMouseKit/SettingsRequest.swift`](../Sources/PureMouseKit/SettingsRequest.swift)) | Empty, or the Settings pane to show (and a sheet over it); asks for Settings to open, and is removed once seen. `show-settings.lock` beside it is an empty lock file |
| `~/Library/Application Support/PureMouse/settings-quit` | Quit PureMouse ([`Sources/PureMouseKit/SettingsRequest.swift`](../Sources/PureMouseKit/SettingsRequest.swift)) | Empty; for 60 s, stops a Settings window that was asked for before the quit from opening after it. The next request to open Settings removes it |
| `~/Library/Preferences/io.github.mblauberg.puremouse.menu.plist` | macOS, for the menu bar app ([`Sources/PureMouseMenu/Menu/StatusMenu.swift`](../Sources/PureMouseMenu/Menu/StatusMenu.swift), [`Sources/PureMouseAppSupport/NotificationPermission.swift`](../Sources/PureMouseAppSupport/NotificationPermission.swift)) | Where the menu bar icon sits, and whether its notifications are off in System Settings (for Settings' hint). The update check's own keys are in the next row |
| `~/Library/Preferences/io.github.mblauberg.puremouse.menu.plist`, the `Updates…` keys | The menu bar app ([`Sources/PureMouseAppSupport/UpdateReminders.swift`](../Sources/PureMouseAppSupport/UpdateReminders.swift), `UpdatePreferences`); Settings › About writes the first one ([`Sources/PureMouseSettingsUI/AboutPane.swift`](../Sources/PureMouseSettingsUI/AboutPane.swift)) | `UpdatesAutomatic`: your answer to "Check for updates automatically?" (absent until you answer or use the switch in About). `UpdatesLaunches`: how many times the menu bar app has started with its icon shown, counted only until you answer. `UpdatesLastCheck`: when the last scheduled request was made, successful or not. `UpdatesETag`: the ETag GitHub sent with the latest release. `UpdatesLatestVersion` and `UpdatesLatestPage`: that release's version and web page. `UpdatesSkippedVersion`: the version you chose **Skip This Version** for. `UpdatesNotifiedVersion`: the newest version a reminder was shown for |
| `~/Library/Preferences/io.github.mblauberg.puremouse.settings.plist` | macOS, for Settings ([`Sources/PureMouseSettingsUI/SettingsWindow.swift`](../Sources/PureMouseSettingsUI/SettingsWindow.swift)) | The Settings window's position and its last tab and segment |

The file and channel formats are in [Configuration](configuration.md) and
[Companion](companion.md). The low-battery warning is a local notification
([`Sources/PureMouseMenu/Model/Notifier.swift`](../Sources/PureMouseMenu/Model/Notifier.swift)).

## The network requests

PureMouse asks GitHub for its latest release in two ways. Both make one HTTPS GET of
`https://api.github.com/repos/mblauberg/PureMouse/releases/latest` and compare the version it
returns with yours ([`Sources/PureMouseAppSupport/UpdateCheck.swift`](../Sources/PureMouseAppSupport/UpdateCheck.swift)),
in an ephemeral session, so no cookies or cache are kept. GitHub sees what any web request shows:
your IP address and a standard user agent naming the app and the system version.

- **On demand.** Pressing **Check for Updates** in Settings › About makes the request once.
- **Once a day, if you allow it.** On the menu bar app's second launch (or the next one that
  finds PureMouse running with its permissions set up), it asks "Check for updates automatically?"
  once. **Check Automatically** turns the daily check on; **Don't Check** leaves it off. The
  switch **Check for updates automatically** in Settings › About shows the answer and changes it,
  and turning it off ends the checks (no request is made while it is off or unanswered).
  - **Interval.** At most one request in 24 hours, counted from the last request whether it
    worked or not, and remembered across restarts and wakes. A failed request waits for the next
    day. The system picks the moment (`NSBackgroundActivityScheduler`): it holds the check back while
    the Mac sleeps or is busy, and PureMouse runs no timer of its own
    ([`Sources/PureMouseAppSupport/BackgroundActivity.swift`](../Sources/PureMouseAppSupport/BackgroundActivity.swift),
    [`Sources/PureMouseAppSupport/UpdateReminders.swift`](../Sources/PureMouseAppSupport/UpdateReminders.swift)).
  - **Network limits.** The request refuses constrained networks (Low Data Mode) and expensive
    ones (a metered hotspot), and carries `If-None-Match` with the ETag of the release it already
    knows, so an unchanged release costs GitHub a 304 and no body.
  - **What it sends.** The request above, with the ETag GitHub gave for the last release. It sends
    no identifier of yours, no version history and no list of what you have set up.
  - **What it does with the answer.** If the release is newer than the running version it posts one
    notification for that version, which opens the release page when clicked, and shows **Update to
    X.Y.Z…** and **Skip This Version** in the menu bar menu until PureMouse is updated or the version
    is skipped. A newer release replaces the earlier reminder, and turning the check off takes it
    down (and the menu row with it). Only a page under `https://github.com/mblauberg/PureMouse/releases`
    is ever opened. The check and the reminders download and install nothing. The reminders are in
    [`Sources/PureMouseAppSupport/UpdateReminders.swift`](../Sources/PureMouseAppSupport/UpdateReminders.swift),
    the schedule in [`Sources/PureMouseAppSupport/BackgroundActivity.swift`](../Sources/PureMouseAppSupport/BackgroundActivity.swift),
    and the question in [`Sources/PureMouseMenu/AppController.swift`](../Sources/PureMouseMenu/AppController.swift).

### Installing an update

**Update to X.Y.Z…** in the menu bar menu is the only thing that downloads a release, and only after
you answer its alert ("Update to PureMouse X.Y.Z?", **Update and Relaunch**). It is never started by
the daily check. PureMouse then makes two more HTTPS GETs, in the same kind of ephemeral session,
to `github.com/mblauberg/PureMouse/releases/download/vX.Y.Z/`: `SHA256SUMS` (under 64 KB) and
`PureMouse-X.Y.Z.dmg` (under 64 MB). GitHub sends the file from its own download servers. They send nothing beyond what any web request shows. The
download goes to a private folder in the temporary directory, never into memory, and is deleted,
with its disk image unmounted, whether the update works or not
([`Sources/PureMouseAppSupport/UpdateInstall.swift`](../Sources/PureMouseAppSupport/UpdateInstall.swift),
[`Sources/PureMouseAppSupport/UpdateInstallLive.swift`](../Sources/PureMouseAppSupport/UpdateInstallLive.swift)).

It installs only what passes four checks, in this order, and stops at the first that fails with the
installed app untouched: the image's SHA-256 matches its line in `SHA256SUMS`; the image holds exactly
one `PureMouse.app`; its code signature is intact and satisfies the code-signing requirement of the
PureMouse that is running (the same certificate, taken from the running app and never from the
download); and its version is newer than yours. A copy goes beside the installed app, is checked
again, and replaces it in one step. The reason and why are in
[ADR 22](adr/0022-update-trust-is-the-signing-requirement.md).

If PureMouse can't replace itself without your password (it is on a read-only disk, or owned by
another account), it downloads nothing, opens the release page and says why. It never asks for a
password. When a check fails the menu shows one line (for example "The update wasn't signed by the
same certificate") and **View Release**; update by hand as the README's **Updating** says. Your settings
and the Accessibility and Input Monitoring grants carry over, because they belong to the same
signature. It stores nothing new.

The background process (`puremouse`) has no network code at all: the check and the
download run in the menu bar app, and `nm` and `strings` on `puremouse` show no URLSession, CFNetwork or endpoint symbol. To turn the
daily check, and with it the **Update to X.Y.Z…** row, off, switch **Check for updates automatically**
off in Settings › About, or choose **Don't Check** when asked; to forget what it stored, `defaults delete io.github.mblauberg.puremouse.menu UpdatesAutomatic`
and the other `Updates…` keys above.

Buttons such as **View Releases**, **View Release**, **Update PureMouse** and **Learn More** open a GitHub page in your browser.

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
([`Sources/HIDPP/Features.swift`](../Sources/HIDPP/Features.swift), `DeviceIdentity`). The
background process reads it to tell two mice of one model apart and keeps it only in
`status.json`, never in the log or the config
([`Sources/puremouse/Identification.swift`](../Sources/puremouse/Identification.swift)). Read the
output before you paste it into an issue.

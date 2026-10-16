# Troubleshooting

Inside the app, the command-line tool is `/Applications/PureMouse.app/Contents/MacOS/puremouse`;
the examples below call it `puremouse`.

## First checks

- **Logs** are in `~/Library/Logs/PureMouse.log`. The first line of each start shows the macOS
  version.
- **Wheels stay native and buttons do nothing:** a permission is missing. Settings › General and
  the log say which. PureMouse restarts itself once it is granted;
  `launchctl kickstart -k gui/$UID/io.github.mblauberg.puremouse` forces a restart.
- **Buttons or wheels misbehave, or settings do not stick:** see [Logi Options+](#logi-options).
- **Wheels silent after a crash:** if PureMouse is killed outright it cannot restore the mouse, so
  with smooth scrolling on the wheels stay silent until it restarts a few seconds later. Turning
  the mouse off and on also resets it.
- **Scrolling and buttons do nothing on another Mac (Universal Control):** PureMouse hands the
  mouse back to macOS while the pointer is on another Mac, so it works there as it does without
  PureMouse; the log says "pointer moved to another Mac" at each crossing and the menu shows "On
  another Mac". If neither happens, check that `universalControl.handOff` is not false. After a
  macOS upgrade the notification it relies on may have changed: see
  [After a macOS upgrade](#after-a-macos-upgrade). Actions bound to buttons (back and forward in
  Safari, for example) do not apply on the other Mac; it gets the buttons' native behaviour.
- **A setting has no effect:** check the menu for a config error. A file that does not load leaves
  the previous settings in effect, and the error names the field.

## Logi Options+

Logi Options+ and PureMouse both take over the mouse's buttons and wheels, and only one can hold
them at a time. When PureMouse sees Options+ running, the menu and the log say so. Quit Options+,
or remove it with Logitech's uninstaller.

## Permissions

| Permission | Why |
|---|---|
| **Accessibility** | To post scrolls, keystrokes and swipes. Until granted, wheels stay native and actions that post events do nothing |
| **Input Monitoring** | To read the mouse over Bluetooth. A receiver works without it |

macOS applies a grant only to processes started after it, so PureMouse checks in the background
and restarts itself once a grant arrives.

Grants are tied to the app's signature. Every release is signed with the same certificate, so an
update keeps them; a build signed by anything else (including an ad-hoc build) has to be granted
again.

## Opening a blocked app

PureMouse is not notarised, so macOS blocks its first launch. Either clear the quarantine flag
**before** opening it:

```sh
xattr -dr com.apple.quarantine /Applications/PureMouse.app
```

or open it, dismiss the warning and choose **Open Anyway** in System Settings › Privacy & Security.
Once macOS has shown that warning, it keeps blocking PureMouse until you answer it, even if you
clear the flag afterwards.

## Starting and stopping

| Command | Effect |
|---|---|
| `puremouse register` | Adds the login items and starts PureMouse (what opening the app does) |
| `puremouse stop` | Stops PureMouse and the menu bar icon until the next login (**Quit PureMouse**) |
| `puremouse unregister` | Stops both and removes the login items. Your config is kept |
| `puremouse menu off` / `on` | Hides or shows the menu bar icon. PureMouse keeps working without it |

## Inspecting a mouse

`puremouse probe` lists every HID++ device with its features and current settings. It only reads,
so it is safe to run at any time. Please attach its output to an issue if a mouse does not work.
For an untested mouse, include the model, connection type (Bluetooth, Bolt or Unifying), and
the adoption line from the log. That line includes the mouse's product ID and the features
PureMouse uses (`?` means a feature query failed); the probe includes the complete feature table,
SmartShift Enhanced state, legacy battery state and haptic capabilities. Move the mouse first
so it is awake. The command does not play effects or change settings.

For button-level detail, stop the agent with `puremouse unregister`, run
`puremouse --verbose run` in a terminal, then start the agent again with `puremouse register`. A
terminal-run PureMouse uses the terminal's permissions.

## After a macOS upgrade

A few actions rely on undocumented macOS interfaces, which a major release can change without
notice. To check every action, press each button, or run `puremouse action <name>` from a terminal
that has Accessibility.

| Interface | Used by | If it stops working, bind instead |
|---|---|---|
| Dock notifications | `missionControl`, `appExpose`, `showDesktop`, `launchpad` | `{"keys": "ctrl+up"}`, `{"keys": "ctrl+down"}`, `{"keys": "f11"}` (the default shortcuts) |
| Navigation-swipe event fields | `navigateBack`, `navigateForward` | `{"keys": "cmd+["}`, `{"keys": "cmd+]"}` (most apps) |
| `CVDisplayLink` (deprecated since macOS 15) | Smooth-scroll frame timing | Nothing: scrolling continues, unsmoothed |
| `IOHIDPostEvent` (deprecated since macOS 11) | `volumeUp`, `volumeDown`, `mute`, `brightnessUp`, `brightnessDown` | `{"run": "osascript -e 'set volume output volume (output volume of (get volume settings) + 6)'"}` and similar |
| Symbolic hot key lookup | `spaceLeft`, `spaceRight` (your own shortcut) | Falls back to Ctrl+Left/Right by itself |
| Front process lookup | Per-app button settings | Falls back to the app owning the frontmost window by itself |
| Universal Control input-state notification | Handing the mouse back while the pointer is on another Mac | Pause PureMouse from the menu while using the other Mac |

macOS 27 stopped honouring the event fields for three-finger Dock swipes. PureMouse does not use
them, and navigation swipes still work on macOS 27.

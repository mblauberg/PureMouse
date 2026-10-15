# How it works

PureMouse finds Logitech receivers and Bluetooth mice through IOKit and speaks HID++ 2.0 to them.
It diverts the buttons and wheels you configure, so their events come to PureMouse instead of
macOS, and posts the matching system events in their place.

## Two processes

`PureMouse.app` holds two programs:

- **The daemon** (`Contents/MacOS/puremouse`) does all the work. It is the only process that
  talks to the mouse, and the only one that needs Accessibility and Input Monitoring. It has no
  window and links no UI framework.
- **The menu bar app** (`Contents/Library/LoginItems/PureMouse Menu.app`) shows status and edits
  the config. It needs no permissions and never opens a device.

Either runs without the other: with the menu bar icon hidden or quit, the mouse behaves exactly as
configured. They talk through two small JSON files and a Darwin notification after each write, so
neither polls. [companion.md](companion.md) is the contract.

launchd runs both from login agents the daemon writes itself, so a replaced app keeps working
without a Developer ID.

## Keeping the mouse in step

The mouse forgets every setting PureMouse gives it whenever it sleeps, reconnects or switches
between a receiver and Bluetooth. PureMouse reapplies them on every reconnect, after the Mac wakes
and on each config reload.

On quit or logout it hands the wheels and buttons back to the mouse first. Nothing is stored on
the mouse or receiver, so they behave normally on any other computer.

## Smooth scrolling

With smooth scrolling on, the wheels report raw movement to PureMouse, which accelerates it and
spreads it across display frames. A display link runs only while a scroll is gliding, so an idle
mouse costs no CPU.

PureMouse posts plain continuous pixel scrolls without trackpad gesture phases, which would make
browsers swipe back and forward. Synthetic scrolls skip the system's natural-scrolling flip, so
PureMouse applies it itself, reading the setting at the start of each scroll.

## Source layout

```
Sources/HIDPP/          protocol only: framing, IOKit transport, request/response handling,
                        typed feature wrappers
Sources/PureMouseKit/   shared by both apps: config model and decoder, status/control channel
Sources/puremouse/      the daemon: applying config, actions, gestures, smooth scrolling, one
                        session per mouse, discovery, reconnects, wake, reload, permissions
Sources/PureMouseMenu/  the menu bar app (AppKit status item and menu, SwiftUI Settings panes)
Tests/                  pure logic: framing and event parsing, config, gestures, scroll maths,
                        config editing
scripts/                build, install, uninstall, package, signing identity, icon
assets/                 app icon (Icon Composer source, compiled icon, README images), menu bar glyph
```

## Protocol references

Logitech does not publish HID++ 2.0, so the feature layouts here were checked against the open
implementations in [Solaar](https://github.com/pwr-Solaar/Solaar) and
[logiops](https://github.com/PixlOne/logiops).

# How it works

PureMouse finds Logitech receivers and Bluetooth mice through IOKit and speaks HID++ 2.0 to them.
It diverts the buttons and wheels you configure, so their events come to PureMouse instead of
macOS, and posts the matching system events in their place.

The decisions behind this design, and the alternatives rejected, are recorded in
[`docs/adr/`](adr/README.md).

## Two processes

`PureMouse.app` holds two programs:

- **The daemon** (`Contents/MacOS/puremouse`) does all the work. It is the only process that
  talks to the mouse, and the only one that needs Accessibility and Input Monitoring. It has no
  window and links no UI framework.
- **The menu bar app** (`Contents/Library/LoginItems/PureMouse Menu.app`) shows status and opens
  Settings. It needs no permissions and never opens a device.
- **The Settings helper** (`Contents/Helpers/PureMouse Settings.app`) is the Settings window, as an
  app of its own that runs only while the window is open. It edits the config.

Either runs without the other: with the menu bar icon hidden or quit, the mouse behaves exactly as
configured. They talk through two small JSON files and a Darwin notification after each write, so
neither polls. [companion.md](companion.md) is the contract.

launchd runs both from login agents the daemon writes itself, so a replaced app keeps working
without a Developer ID. `LoginItem` decides what to start, stop or register and in what order; a
`LoginService` (launch agents) does it, which keeps the policy testable and lets another
mechanism replace launchd ([ADR 0018](adr/0018-login-service-seam.md)). Starting at login and
running now are separate: `login on|off` change the first, `start` and `stop` the second.

## Keeping the mouse in step

The mouse forgets every setting PureMouse gives it whenever it sleeps, reconnects or switches
between a receiver and Bluetooth. PureMouse reapplies them on every reconnect, after the Mac wakes
and on each config reload.

On quit or logout it hands the wheels and buttons back to the mouse first. Nothing is stored on
the mouse or receiver, so they behave normally on any other computer.

## Universal Control

Universal Control forwards only native mouse input to another Mac, so scrolls and button presses
PureMouse diverts would not reach it. When the pointer crosses to another Mac, macOS posts an
undocumented per-user Darwin notification (`user.uid.<uid>.com.apple.universalcontrol.inputstate`);
its state has bit 0x2 set while the pointer is away and 0x1 while the keyboard is. PureMouse
watches it (`UniversalControlWatcher`, no polling) and, while the pointer is away, hands the wheels
and diverted buttons back to macOS, keeping DPI and the other settings. When the pointer returns it
diverts them again. `universalControl.handOff: false` turns this off.

## Which devices and features

A device is adopted if it says it is a mouse or trackball, or has adjustable DPI (0x2201, or
0x2202 on mice such as the G Pro X 2 Superstrike, which have no 0x2201). Keyboards, numpads,
presenters and receivers report a control list too, so that alone does not qualify them. Each
feature a mouse reports is then used and nothing else is asked.

DPI goes through 0x2201, else 0x2202. The value is snapped to the sensor's list and read back. If
the mouse reads back something else, as a G305 in onboard mode does (its profile, 0x8100, owns the
resolution), DPI is reported as not controllable and the log says so once. PureMouse never writes
0x8100. A battery is read through 0x1004, else 0x1000, else 0x1001; the last gives a level only,
never a percentage.

### Deferred features

Not used, and why:

- 0x2205 (pointer speed, the MX Ergo's): whether a write survives a power cycle is unestablished,
  and PureMouse writes nothing a mouse keeps.
- 0x2120 (a flag-only wheel mode with no diversion): it cannot hand wheel input to PureMouse.
- 0x8100 (onboard profiles): persistent by design.
- 0x1001 percentages, and the Ergo's persistent control diversion (0x71 flag): only the temporary
  bit is ever set.

## Smooth scrolling

With smooth scrolling on, the wheels report raw movement to PureMouse, which accelerates it and
spreads it across display frames. A display link runs only while a scroll is gliding, so an idle
mouse costs no CPU. Thumb-wheel actions (volume, zoom, tabs and the rest) take over the thumb wheel
alone, even with smooth scrolling off; where the thumb wheel scrolls, it then scrolls without the
glide.

A notched wheel (0x2130, as on the Signature Plus M750 and the MX Ergo) reports whole notches
once PureMouse asks for them; each notch becomes the same per-notch distance a 0x2121 notch is
(40 px) and glides the same way. Asking is a temporary reporting bit, so the wheel is native again
whenever PureMouse lets go or the mouse reconnects, and the mouse is never given a persistent
setting. When a mouse has both features, 0x2121 is the wheel.

PureMouse posts plain continuous pixel scrolls without trackpad gesture phases, which would make
browsers swipe back and forward. Synthetic scrolls skip the system's natural-scrolling flip, so
PureMouse applies it itself, reading the setting at the start of each scroll.

## Per-app settings

Buttons, the thumb wheel and smooth scrolling can differ per app. Nothing watches app switches:
PureMouse asks which app is frontmost when a button some app binds is pressed, and which is under
the pointer when a scroll or a thumb-wheel movement starts, and only when some app has settings of
that kind. Each answer costs microseconds to a millisecond, and an idle mouse still costs nothing.

## Source layout

```
Sources/HIDPP/          protocol only: framing, IOKit transport, request/response handling,
                        typed feature wrappers
Sources/PureMouseKit/   shared by both apps: config model and decoder, status/control channel
Sources/puremouse/      the daemon: applying config, actions, gestures, smooth scrolling, one
                        session per mouse, discovery, reconnects, wake, reload, permissions
Sources/PureMouseAppSupport/
                        the menu side's logic, without AppKit or SwiftUI: the daemon link,
                        config editing and saving, select by pressing, where files live, status
                        words, update check, battery alerts, opening Settings
Sources/PureMouseMenu/  the menu bar app (AppKit status item and menu, no SwiftUI); the menu's
                        rows come from `MenuPlan`, which `StatusMenu` renders
Sources/PureMouseSettingsUI/
                        the Settings window and its SwiftUI panes
Sources/PureMouseSettings/
                        the Settings helper app around them
Sources/HIDPPTesting/   test support only: in-memory transport and stateful HID++ mouse from probe dumps
Tests/                  request handling and device behaviour against fakes, framing and event parsing,
                        config, gestures, scroll maths, config editing, the menu's rows
scripts/                build, install, uninstall, release, signing identity, icon
assets/                 app icon (Icon Composer source, compiled icon, README images), menu bar glyph
```

## Protocol references

Logitech does not publish HID++ 2.0, so the feature layouts here were checked against the open
implementations in [Solaar](https://github.com/pwr-Solaar/Solaar) and
[logiops](https://github.com/PixlOne/logiops).

SmartShift Enhanced and haptic layouts follow Solaar's
[`SmartShiftEnhanced`, `ScrollRatchetTorque` and `PlayHapticWaveForm`](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py).
Legacy battery status follows
[`decipher_battery_status`](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/hidpp20.py)
and its function-0 broadcast handler. SmartShift parse tests use response parameters from
[OpenLogi's MX Master 4 and Anywhere 3S fixtures](https://github.com/AprilNEA/OpenLogi/tree/master/fixtures/devices),
available under its [MIT licence](https://github.com/AprilNEA/OpenLogi/blob/master/LICENSE-MIT).
These layouts have not been tested on those mice by this project.

The 0x2130 (low-resolution wheel) and 0x2202 (extended adjustable DPI) layouts are inferred from
Solaar's settings templates (`LowresMode`, `ExtendedAdjustableDpi`, `produce_dpi_list`), not checked
against a capture: no raw reply of either from a real mouse is public, and the Linux driver has no
code for them. The 0x1001 (battery voltage) layout follows Solaar's `decipher_battery_voltage` and
the driver's `hidpp20_battery_map_status_voltage`, which agree, and one raw sample (a G915). The
direction of a positive 0x2130 notch count rests on Solaar alone and awaits an owner with an M750
or MX Ergo. Because a write cannot be assumed to take, PureMouse reads the 0x2130 reporting byte
back after diverting it and leaves a wheel that does not confirm scrolling natively, and reads the
DPI back from every axis it wrote. The MX Master 3S, MX Master 4 and MX Ergo fixtures are raw
captures from OpenLogi; the G305 and Superstrike fixtures are hand-built from Solaar's device
listings, and say so in their headers. Layouts were read for protocol facts, and no code was
copied.

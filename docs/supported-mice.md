# Supported mice

PureMouse keeps no list of models. It adopts a Logitech device that says it is a mouse or trackball
over HID++ 2.0, or that has adjustable DPI, and uses each feature that mouse reports. Keyboards,
numpads, presenters, remotes, touchpads and receivers are left alone. [How it
works](how-it-works.md#which-devices-and-features) has the rules, and the
[README](../README.md#supported-mice) the short version.

Mice connect over Bluetooth or through a Logi Bolt or Unifying receiver, and both are picked up
automatically.

## By model

What each mouse reports, and so what PureMouse turns on for it:

| Mouse | What PureMouse uses | Where the feature list comes from |
|---|---|---|
| MX Master 3S | Buttons, gestures, DPI, both wheels, SmartShift and battery | Tested on the mouse: it is the development mouse. Also a raw capture (OpenLogi) |
| MX Master 3 / 3 for Business | The same, including older firmware's battery reporting | The family's usual features |
| MX Master 4 | The same, plus haptic feedback as an action | A raw capture (OpenLogi) |
| MX Anywhere 3 / 3S | Buttons, DPI, smooth scrolling, SmartShift and battery | The family's usual features; the 3S's SmartShift replies from OpenLogi |
| MX Vertical / Lift | Buttons, DPI and battery | The family's usual features |
| Signature Plus M750 | Buttons, DPI, smooth scrolling on its notched wheel and battery | A user's `puremouse probe` output ([#1](https://github.com/mblauberg/PureMouse/issues/1)) |
| MX Ergo | Buttons, smooth scrolling on its notched wheel and battery; no DPI control | A raw capture (OpenLogi) |
| G305 and other G-series mice in onboard mode | Battery and, where the mouse accepts it, DPI; in onboard mode DPI cannot be set and the status says so | Solaar's device listing |
| G Pro X 2 Superstrike | DPI and battery | Solaar's device listing |

Tested on hardware: the MX Master 3S. The other rows are what each mouse reports, not what
PureMouse has been seen doing on it. The captures and listings are
kept as test fixtures in [`Tests/Fixtures/probe`](../Tests/Fixtures/probe), each with its source in
its header, and the tests run PureMouse against them; [How it
works](how-it-works.md#protocol-references) lists the protocol references.

## Limits

- PureMouse never writes the settings a mouse keeps through a power cycle, such as onboard
  profiles. That is why a G305 in onboard mode does not get DPI control.
- A mouse that reports only a battery level shows that level, not a percentage.
- A feature PureMouse does not use yet, and why, is under [Deferred
  features](how-it-works.md#deferred-features).

## Another mouse

Attach [`puremouse probe` output](troubleshooting.md#inspecting-a-mouse) to a [Device
support](https://github.com/mblauberg/PureMouse/issues/new/choose) issue. It only reads, and
[Privacy](privacy.md#what-puremouse-probe-prints) says what it prints. A report that a listed
mouse works, or doesn't, is just as welcome.

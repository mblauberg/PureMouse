# 3. Feature drivers: designed now, built with keyboard support

## Status

Accepted, not built

## Context

A driver per HID++ feature was proposed for the device model. Mice like the M750 need only
absence handling and a capability map. Logitech keyboards would add three or more independent
setting features.

## Decision

Inputs (controls, main wheel, thumb wheel) stay concrete in `Session`, because their order and
coupling are the invariants. Independent settings get a `SettingDriver` protocol, designed now and
built as the first task of keyboard support, moving DPI, SmartShift, battery and haptics under the
fake-device tests of [ADR 1](0001-transport-protocol-and-fake-device.md).

## Alternatives rejected

- Drivers for everything now: it reshapes the most invariant-dense code for a future benefit, and
  generic iteration hides the restore order.
- Never: keyboards would then be a second copy of `Session`.

## Consequences

- Session changes for multi-device support stay small.
- The first keyboard change is a pure move with green tests.
- If a third SmartShift-like variant or a fourth optional mouse setting arrives first, the drivers
  are built then.

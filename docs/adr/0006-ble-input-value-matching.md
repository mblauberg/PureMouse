# 6. Bluetooth HID++ input through vendor-page value matching

## Status

Proposed. Gated by the Bluetooth input spike, which must answer the three questions below, and by
the measured cost of a moving Bluetooth mouse meeting its budget.

## Context

Bluetooth mice are matched by transport, and a manager-level report callback wakes the daemon for
every pointer report (and every key report of a Logitech Bluetooth keyboard), only to discard it.

## Decision

Use per-device input: report callbacks for receivers, and, for Bluetooth, input value matching on
the vendor usage pages (0xFF43, 0xFF00) with value callbacks, so pointer and key reports never wake
the process. Each value is rebuilt into a HID++ report. This ships only if the spike shows that:

1. the long HID++ input is a single 19-byte element;
2. the element queue delivers a value equal to the previous one (two identical raw XY reports in a
   row are normal in a slow gesture);
3. device-level callbacks run on the manager's queue (the main queue).

Otherwise report callbacks stay and the measured cost is published in `docs/how-it-works.md`.

## Alternatives rejected

- Per-device report callbacks only: the same wake-ups.
- Seizing or opening a separate interface: Bluetooth HID exposes one device, and seizing it would
  take the pointer away from macOS.

## Consequences

- Removes the per-report hop to the main thread and the linear lookup.
- A Logitech Bluetooth keyboard's keystrokes no longer reach the daemon, which also helps privacy.
- The new input path needs live checks on two mice.

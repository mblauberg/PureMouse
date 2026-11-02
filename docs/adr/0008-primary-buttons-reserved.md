# 8. The primary buttons are never bound or diverted

## Status

Accepted

## Context

Select by pressing diverts every pressable control that is not bound. A mouse that reports the left
or right button (controls 0x0050, 0x0051) as divertable would have its click swallowed, and a
binding written by hand in hex could divert it for good.

## Decision

`Config.reservedControls` holds 0x0050 and 0x0051. The decoder drops bindings for them, at the top
level, in apps and in devices, with a warning, and the session never counts them as bound or
pressable.

## Alternatives rejected

- A guard in the menu only: hand edits and capture would still reach the buttons.

## Consequences

- Nobody can remap left or right click through PureMouse, which is intended.
- `docs/configuration.md` documents the rule.

# 10. Menu memory policy: measured budgets

## Status

Accepted. The footprint rig has run on the spare test Mac (2026-11-02; `docs/companion.md`,
Footprint), which fixes the budgets below, and the `MallocSpaceEfficient` gate passed. The budgets
were measured again the same day with Settings as a helper app ([ADR 9](0009-settings-helper-app.md)).

## Context

The README's 14 MB for the menu bar app was its fresh-launch figure. The rig measured about 6 MB
more once the menu had been opened (about 20 MB) before `MallocSpaceEfficient` was set. A bare
AppKit app with a five-item `NSMenu` goes
from 10.8 to 15.2 MB on first open on the same Mac: most of the cost is AppKit's menu machinery, as
dirty freed malloc memory. An earlier target of 10 MB is below that floor.

## Decision

- Budgets are measured numbers, in `scripts/measure-menu.budgets`: the median of 5 rig runs plus
  2 MB, rounded up, lowered when a change earns it. With the variable set: fresh launch at most
  11 MB; after the menu has been opened, at most 15 MB once and after ten opens; after 200 status
  doorbells, 11 MB.
- The Settings helper's footprints follow the same rule: the menu app after the helper quits, once
  or five times, at most 11 MB, and the helper itself at most 37 MB with its window open. Its cold
  start, from the menu being asked to the window on screen, is budgeted at the median plus half,
  rounded up to 100 ms (800 ms).
- `MallocSpaceEfficient=1` is set for the menu app (launchd environment and `LSEnvironment`) and the
  Settings helper (`LSEnvironment`). The gate was the baseline build against the branch build, 5
  runs each: 14.08 MB after three opens against 19.86 (0.71 times, the rule is at most 0.75), and
  10.14 MB fresh against 13.83 (`docs/companion.md`, Footprint).
- `NSMenu` stays.

## Alternatives rejected

- A custom panel instead of `NSMenu`: loses native menu behaviour (type-select, key equivalents,
  accessibility, Liquid Glass) and has its own unmeasured cost.
- Relaunching the menu after each close: icon flicker and launchd's throttle.
- Accepting 25 MB and only correcting the README: honest, but the variable passed its gate.

## Consequences

- `MallocSpaceEfficient` is undocumented: if a macOS release ignores it the saving goes, never
  correctness, so the rig run is repeated after each major macOS release.
- CI cannot measure GUI memory; the rig script does, and its numbers are recorded with the budgets.

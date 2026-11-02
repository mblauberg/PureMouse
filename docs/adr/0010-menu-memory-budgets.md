# 10. Menu memory policy: measured budgets

## Status

Proposed. Gated by the footprint rig run on the spare test Mac, which finalises the numbers and
decides whether `MallocSpaceEfficient` ships.

## Context

The README's 14 MB for the menu bar app is its fresh-launch figure. Opening the menu once adds
about 9 MB, so the installed menu app sits near 25 MB. A bare AppKit app with a five-item `NSMenu`
goes from 12 to 19-21 MB on first open: most of the cost is AppKit's menu machinery, as dirty freed
malloc memory. An earlier target of 10 MB is below that floor.

## Decision

- Budgets are measured numbers: fresh launch at most 12 MB, after the menu has been opened at most
  18 MB. The rig run fixes them and they are published.
- `MallocSpaceEfficient=1` is set for the menu app (launchd environment and `LSEnvironment`) only if
  the rig run confirms its saving (measured locally: 16-18 MB after three opens, against 24-26).
- `NSMenu` stays.

## Alternatives rejected

- A custom panel instead of `NSMenu`: loses native menu behaviour (type-select, key equivalents,
  accessibility, Liquid Glass) and has its own unmeasured cost.
- Relaunching the menu after each close: icon flicker and launchd's throttle.
- Accepting 25 MB and only correcting the README: honest, and the fallback if the variable is
  declined.

## Consequences

- `MallocSpaceEfficient` is undocumented: if a macOS release ignores it the saving goes, never
  correctness, so the rig run is repeated after each major macOS release.
- CI cannot measure GUI memory; the rig script does, and its numbers are recorded with the budgets.

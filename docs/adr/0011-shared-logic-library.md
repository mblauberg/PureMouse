# 11. A shared logic library and an `AppModel` split

## Status

Accepted and built. `PureMouseAppSupport` holds the shared logic, tested in
`Tests/PureMouseAppSupportTests`; `AppModel` composes `ConfigStore`, `DaemonLink` and
`CaptureController`, and the status menu is built from `MenuPlan` (`MenuPlanTests`).

## Context

The menu's logic sits in an executable target. `AppModel` mixes config editing, the daemon link
and capture behind static `Paths`, so it has no tests. The Settings helper
([ADR 9](0009-settings-helper-app.md)) needs the same code.

## Decision

A new library target, `PureMouseAppSupport`, with no AppKit or SwiftUI, holds the pure logic, with
file locations injected. `AppModel` splits into `ConfigStore`, `DaemonLink` and
`CaptureController`, and the status menu is built from a testable plan. Each step is a
behaviour-preserving move with the existing tests as the oracle, done before the helper.

## Alternatives rejected

- Symlinking or duplicating files into both targets: they drift.
- Moving the logic into `PureMouseKit`: Kit is shared with the daemon and must stay data only.
- Doing the split inside the helper change: a diff too large to review.

## Consequences

- Reset, reload and flush paths become testable against temporary directories.
- One more target in `Package.swift`, and test files move.

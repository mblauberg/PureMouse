# PureMouse: agent notes

PureMouse is a native macOS utility for Logitech mice, in Swift 6 with no dependencies. A headless
daemon speaks HID++ 2.0 to the mouse, a menu bar app shows status, and an on-demand Settings helper
edits `~/.config/puremouse/config.json`. `README.md` says what it does for users.

**Quality bar:** reliable, lightweight, intuitive, modern, macOS native feeling, clean, minimalistic,
configurable, flexible and easy to maintain. Footprint: [ADR 10](docs/adr/0010-menu-memory-budgets.md),
[development](docs/development.md#ci). Native and minimal: [ui-design](docs/ui-design.md#principles).
Configurable: [configuration](docs/configuration.md). Maintainable:
[how-it-works](docs/how-it-works.md#invariants), [ADR 11](docs/adr/0011-shared-logic-library.md).

This file is the always-loaded summary. Durable detail lives in `docs/`; read the doc for the area
you touch (see [Where things are](#where-things-are)).

## Process

- Work is tracked in GitHub issues on `mblauberg/PureMouse` (forms: epic, feature, task, bug,
  device). The issue owns scope and status; docs own durable rules.
- Branch off `main`, one change per pull request, and fill in
  [the template](.github/pull_request_template.md), including Agent evidence. Merging needs the
  `test` check, which the `main` ruleset requires.
- A change that alters behaviour updates the doc that owns it in the same pull request:
  `docs/configuration.md`'s field tables for config, the UI pages for UI, and the ADR when a
  decision changes (amend the record; [ADR index](docs/adr/README.md)).
- Releases are the owner's: a `v*` tag ruleset lets only the owner create release tags. The steps
  are in [development.md, Releases](docs/development.md#releases).

## Commands

```sh
swift build && swift test                 # every change; CI runs the same
swift test --filter <Suite>               # one suite while iterating
scripts/tests/run.sh [name]               # the build and release scripts' tests
.build/debug/puremouse probe              # read-only; safe beside the installed daemon
scripts/release.sh --dry-run --version 0.0.0-ci.local   # what CI's bundle step does
```

There is no linter; the compiler and the tests are the checks. Running a dev daemon, the menu or
Settings from a build, the dev hooks and screenshots are in
[development.md](docs/development.md#test).

## Swift 6.3 in CI

CI builds with Xcode 26 (Swift 6.3); a local Xcode 27 (Swift 6.4) can pass what CI cannot.

- A macOS 27-only API goes inside `#if compiler(>=6.4)`.
- Never pass a method as a SwiftUI closure argument (`Binding(get:set: select)`): Swift 6.3 crashes
  in IRGen on its `@isolated(any)` thunk, so write `set: { select($0) }`.
- `.map(Data.init)` is ambiguous to Swift 6.3; write `.map { Data($0) }`.

## Hard rules

Safety and the live machine:

- The user's live config is `~/.config/puremouse/config.json`. Never edit the live config to test:
  run a dev daemon against a copy.
- Running `.build/debug/PureMouseMenu` or `PureMouseSettings` without `PUREMOUSE_CONFIG`,
  `PUREMOUSE_DAEMON` and `PUREMOUSE_COMPANION_DIR` set edits the live config and drives the
  installed agent. Set all three first.
- Two daemons fight over the mouse: stop the installed agent
  (`/Applications/PureMouse.app/Contents/MacOS/puremouse unregister`) before running a dev daemon.
- Never start or re-enable Logi Options+ (`com.logi.cp-dev-mgr`): it fights PureMouse over the
  mouse.
- Nothing may be persisted on the mouse or receiver: they must work normally without PureMouse.
  Never write a persistent diversion, haptic strength, enable flags or configuration, or onboard
  profiles (0x8100). The one exception is pairing or unpairing a device on a Unifying or Bolt
  receiver, started by the person in Settings and confirmed in an alert, never stored, replayed or
  offered as an action ([ADR 23](docs/adr/0023-receiver-pairing-is-the-one-persistent-write.md);
  not built yet).
- The primary clicks 0x0050 and 0x0051 are never bound or diverted
  ([ADR 8](docs/adr/0008-primary-buttons-reserved.md)).
- Over SSH nobody can answer a Gatekeeper dialog or grant permissions: leave those to whoever is at
  the Mac. Clear the quarantine flag before a first launch.
- Run the footprint rig and `PUREMOUSE_DEV_AX_DUMP` on a spare Mac, never the one whose PureMouse
  you use.
- Machine-specific notes go in the uncommitted `CLAUDE.local.md`.

Signing and release:

- Builds are signed by `scripts/sign-bundle.sh`, inside out, no `--deep`, always the hardened
  runtime ([ADR 14](docs/adr/0014-signing-identity-is-configuration.md)).
- Release with `PUREMOUSE_SIGN_IDENTITY=PureMouse ./scripts/release.sh` on a Mac holding that
  identity. A release signed by any other identity makes every user grant permissions again.
- Every GitHub Action is pinned to a full commit SHA.

Design:

- Before 1.0 nothing is kept for backward compatibility: the menu and daemon ship together, and
  config, status and control formats change freely (say so in the release notes). Add no frozen
  readers, fallbacks for older versions, legacy shims or migrations.
- No dependencies. No AppKit or SwiftUI in the daemon or `PureMouseKit`; the menu bar app links
  AppKit only, and only `PureMouseSettingsUI` and the Settings helper link SwiftUI.
- Zero idle CPU: no polling and no timers, beyond the bounded exceptions in
  [how-it-works](docs/how-it-works.md#threads-and-idle-cost). The menu bar app and Settings never
  open HID devices.
- `Sources/HIDPP` is protocol only; policy lives in `Sources/puremouse`. `PureMouseKit` is data
  only: no HID, no event posting, no `Log`.
- All HID and HID++ work runs on the main actor, served by `runMainLoop()`, never `dispatchMain()`.
- Anything applied to the mouse belongs in `Session.apply()`: the mouse forgets it on reconnect.
- `LoginService.stop` waits for the old daemon to finish restoring the mouse; nothing starts a
  replacement before it returns ([companion](docs/companion.md#login-and-lifecycle)).
- Give any new numeric config field a range, and keep `ConfigGoldenTests` identical unless
  regenerating it on purpose.
- User-facing text follows [ui-language](docs/ui-language.md); layout and controls follow
  [ui-design](docs/ui-design.md). Change either page in the same pull request as the UI it governs.

## Where things are

Read the doc before changing its area. ADRs are in [docs/adr/](docs/adr/README.md).

Daemon and protocol:

- Sessions, diversion, scrolling, adoption, capture, Universal Control, battery, DPI, permissions:
  [how-it-works.md, Invariants](docs/how-it-works.md#invariants); ADRs 1, 2, 3, 6.
- Adding a button, action, device feature or config section:
  [development.md, Extending](docs/development.md#extending).
- Mice and the features they report: [supported-mice.md](docs/supported-mice.md).
- Undocumented macOS interfaces and what breaks after an OS upgrade:
  [troubleshooting.md](docs/troubleshooting.md#after-a-macos-upgrade).
- Logging: ADRs [7](docs/adr/0007-log-rotation.md) and [16](docs/adr/0016-daemon-owns-its-log.md).

Config and the channel:

- Config format, per-app and per-device settings: [configuration.md](docs/configuration.md);
  ADRs [5](docs/adr/0005-config-v2-device-overrides.md) and
  [12](docs/adr/0012-multi-device-settings-scopes.md).
- Status and control files, config writes and locks, login and lifecycle, low-battery
  notifications: [companion.md](docs/companion.md); ADRs 4, 9, 18.
- Files written, the network request, what the log holds: [privacy.md](docs/privacy.md).
- Update check: [ADR 21](docs/adr/0021-scheduled-update-check.md); one-click install: [ADR 22](docs/adr/0022-update-trust-is-the-signing-requirement.md).

Settings and menu UI:

- Layout, controls, disclosure, accessibility: [ui-design.md](docs/ui-design.md).
- Code-level UI rules (tabs, sizing, scopes, Apps, notices):
  [ui-design.md, Implementation](docs/ui-design.md#implementation).
- Device card on Mouse > Buttons (`DeviceCard`, `DeviceArt`): [ui-design.md, Device card](docs/ui-design.md#device-card).
- Words, casing and the glossary: [ui-language.md](docs/ui-language.md).

Build, release and memory:

- Build, test, dev runs, dev hooks, screenshots, other Macs, signing, releases, CI, icon:
  [development.md](docs/development.md); ADRs 14, 15, 17, 19, 20.
- Menu bar app memory: [companion.md, Footprint](docs/companion.md#footprint),
  [development.md, Footprint rig](docs/development.md#footprint-rig), ADR 10.

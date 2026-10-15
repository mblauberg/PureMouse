# PureMouse: agent notes

Read `README.md` first for what PureMouse does, its config and its layout. This file covers how to
work on it safely.

## Workflow

- Build and test: `swift build && swift test`. The tests cover pure logic only; anything touching
  the mouse needs a live check.
- Live check: `.build/debug/puremouse probe` is read-only and safe alongside the daemon (it uses its
  own HID++ software IDs). To run a dev build, stop the agent first (two daemons fight over the
  mouse) with `/Applications/PureMouse.app/Contents/MacOS/puremouse unregister`, then run
  `.build/debug/puremouse --verbose run ./config.example.json`. A terminal-run daemon uses the
  terminal's permissions and never restarts itself. Finish with `./scripts/install.sh`, which
  rebuilds, re-signs and restarts the agent, and check `~/Library/Logs/PureMouse.log`.
  (`puremouse permissions` answers for whoever launches it, so from a terminal it reports the
  terminal's permissions, not the app's.)
- The user's live config is `~/.config/puremouse/config.json`; keep `config.example.json` in step
  with it (its test checks shape, not values). Config changes apply with
  `launchctl kill HUP gui/$UID/io.github.mblauberg.puremouse`, no rebuild.
- Other Macs: `./scripts/package.sh` builds the universal release zip. On a test Mac over SSH,
  drive the installed app with `puremouse register`/`unregister`. Over SSH nobody can answer a
  Gatekeeper dialog or grant permissions, so leave those to whoever is at the Mac. Machine-specific
  notes belong in the uncommitted `CLAUDE.local.md`.
- Releases: tag `vX.Y.Z` on a clean `main` (the bundle version is the tag without the `v`), run
  `./scripts/package.sh` on a Mac holding the `PureMouse` signing identity, and attach
  `.build/dist/PureMouse-X.Y.Z.zip` to a GitHub release with its SHA-256. A release signed by any
  other identity makes every user grant permissions again. CI (`.github/workflows/ci.yml`) builds,
  tests and bundles ad hoc on each push.
- The icon is an Icon Composer document, `assets/AppIcon.icon`: a top-down mouse in three
  monochrome glass layers (buttons with the centre seam, palm, floating wheel), grey fills with
  light and dark specializations, on the system's light/dark background, so macOS 26+ renders
  light, dark, clear and tinted variants. After changing it, run `./scripts/make-icon.sh` (needs
  Xcode 26+ and `rsvg-convert`) and commit the compiled `Assets.car`, `AppIcon.icns` (macOS 14/15
  fallback), the README PNGs and `MenuBarIcon.pdf`. `assets/MenuBarIcon.svg` is the same mouse as
  an 18x18 pt template (alpha only; the wheel is a slot, gaps are 1-1.5 pt on the half-point grid
  so they stay crisp at 1x and 2x); it is plain clip and even-odd paths because rsvg rasterises
  SVG masks in the PDF. The menu bar app loads `MenuBarIcon.pdf`. Keep the two in step.
- When behaviour changes, update the README's field tables and this file in the same change.

## Invariants

- `Sources/HIDPP` is protocol only (framing, transport, typed feature wrappers) and must stay
  free of policy. Config, actions and scrolling live in `Sources/puremouse`.
- All HID and HID++ work runs on the main actor. IOKit and CoreVideo callbacks hop to it
  (`MainActor.assumeIsolated` / `DispatchQueue.main`); keep it that way. The process serves the
  main queue with `runMainLoop()` (a `CFRunLoop` on the main thread), never `dispatchMain()`:
  that drains the main queue off the main thread, and on macOS 26 and earlier `assumeIsolated`
  then traps (it crashed on SIGTERM, before restoring the mouse).
- Device settings are volatile: the mouse forgets them on every reconnect. Anything applied to
  it belongs in `Session.apply()`, which runs on adoption, reconnect, wake and reload.
- On SIGTERM/SIGINT, `Session.restore()` returns the mouse to native behaviour (wheels first).
  Nothing may be persisted on the device or receiver: they must work normally without PureMouse.
- A session that is `finished` (closed or restored) must not touch the device again; the daemon
  stops adopting once `shuttingDown`.
- Keep it light: no AppKit, SwiftUI or dependencies. Idle cost is zero CPU; the display link
  runs only while a scroll is gliding.

## Easy to break

- Scroll events carry whole pixels only. Setting the fractional point-delta fields replaces the
  integer delta with its truncation and silently loses distance.
- Scroll events have no gesture phases. Phased horizontal scrolls make browsers swipe back and
  forward.
- Synthetic scrolls skip the system's natural-scrolling flip, so `ScrollEngine` applies it,
  re-reading the setting at the start of each burst.
- The wheels are only diverted when PureMouse can post events (Accessibility). Diverting without it
  silences them.
- `restore()` decides whether to hand the wheels back from `Session.wheelsMayBeDiverted`, not
  from the current config: after a reload that drops `smoothScroll`, the replacement session
  inherits the flag and keeps it until its own apply has set the wheels native.
- Permission checks are cached per process. The launchd-run daemon polls a child
  (`puremouse permissions`) and restarts itself when a grant arrives (`Daemon.restartWhenGranted`).
- HID++ software IDs rotate per request so a late reply cannot complete a newer request.
- A receiver slot that does not answer is retried after 1, 2, 4 and 8 s (`Daemon.adoptSlot`);
  after that only its connection notification brings it back, so idle cost stays zero. A slot
  ignored as not a mouse is identified again when a notification carries a different wireless
  product ID (a new device paired into it).
- `puremouse register` (and opening the app from the Finder, i.e. no arguments inside a bundle)
  writes `~/Library/LaunchAgents/<bundle id>.plist` pointing at its own binary and bootstraps it,
  booting out any running instance first (`LoginItem.swift`). Not `SMAppService`: without a
  Developer ID team, launchd pins its agents to the registering build ("needs LWCR update"), so a
  replaced app's agent fails to spawn with EX_CONFIG, and re-registering did not reliably clear it.
- Builds are signed with the `PureMouse` code-signing identity (self-signed,
  `scripts/make-cert.sh`). The permission grants are keyed to identifier plus certificate, which
  also holds on Macs that do not trust the certificate; an ad-hoc signature makes macOS drop them on
  every install. install.sh stops the agent before replacing the binary.
- Gatekeeper: launching a quarantined copy parks it at `_dyld_start` behind an on-screen dialog.
  On a test Mac, later launches at that path stayed parked even after clearing the flag and putting
  a fresh copy there (presumably until the dialog is answered). Clear the flag before the first
  launch.
- Some actions use undocumented interfaces: `CoreDockSendNotification` (it returns 0 even for
  unknown names, so failure is silent) and the navigation-swipe CGEvent fields. macOS 27 already
  stopped honouring the dock-swipe fields, which PureMouse does not use. After an OS upgrade, check
  them with `puremouse action <name>`; README's "After a macOS upgrade" lists the keystroke
  fallbacks.
- Logi Options+ fights PureMouse over the mouse (its agent is `com.logi.cp-dev-mgr`). The daemon
  logs an error at start if it sees any of its processes (`LogiOptions`); only this user's process
  names are readable, so a root-run updater goes unseen.
- Config numbers are range-checked when decoded (`decodeIfPresent(_:forKey:in:)` in
  `Config.swift`); give any new numeric field a range too. An unchecked value can overflow an `Int`
  or `Duration` conversion mid-session, and during a reload that crash comes after the old
  session has closed, so the mouse is never restored and launchd relaunches into the same crash.
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per session; if
  the list cannot be read, the configured value is sent unchanged.

## Extending

- New action: a case in `Action`, a name in `Action.named`, handling in `SystemActions.perform`.
- New device feature: a wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, and a parse test in `Tests/HIDPPTests`.
- Per-app scroll settings: choose a different `ScrollEngine.Profile` when a burst starts.
- Scroll feel: `ScrollAcceleration` (curve) and `ScrollAnimator` (two-part easing) in
  `ScrollModel.swift`, covered by `ScrollModelTests`.
- Protocol references: Solaar (`hidpp20.py`), logiops, Mac Mouse Fix. `puremouse probe` dumps the
  raw feature state for comparison.

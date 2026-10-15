# mxd: agent notes

Read `README.md` first for what mxd does, its config and its layout. This file covers how to
work on it safely.

## Workflow

- Build and test: `swift build && swift test`. The tests cover pure logic only; anything touching
  the mouse needs a live check.
- Live check: `.build/debug/mxd probe` is read-only and safe alongside the daemon (it uses its
  own HID++ software IDs). To run a dev build, stop the agent first (two daemons fight over the
  mouse) with `/Applications/mxd.app/Contents/MacOS/mxd unregister`, then run
  `.build/debug/mxd --verbose run ./config.example.json`. A terminal-run daemon uses the
  terminal's permissions and never restarts itself. Finish with `./scripts/install.sh`, which
  rebuilds, re-signs and restarts the agent, and check `~/Library/Logs/mxd.log`.
  (`mxd permissions` answers for whoever launches it, so from a terminal it reports the
  terminal's permissions, not the app's.)
- The user's live config is `~/.config/mxd/config.json`; keep `config.example.json` in step
  with it (its test checks shape, not values). Config changes apply with
  `launchctl kill HUP gui/$UID/local.mxd`, no rebuild.
- Other Macs: `./scripts/package.sh` builds the universal release zip. The spare Mac `workshop`
  (macOS 26, command line tools only) is reachable as `ssh workshop-fabric`; install under
  `~/Applications` there and drive it with `mxd register`/`unregister`. Over SSH nobody can answer
  a Gatekeeper dialog or grant permissions, so leave those to the user.
- When behaviour changes, update the README's field tables and this file in the same change.

## Invariants

- `Sources/HIDPP` is protocol only (framing, transport, typed feature wrappers) and must stay
  free of policy. Config, actions and scrolling live in `Sources/mxd`.
- All HID and HID++ work runs on the main actor. IOKit and CoreVideo callbacks hop to it
  (`MainActor.assumeIsolated` / `DispatchQueue.main`); keep it that way. The process serves the
  main queue with `runMainLoop()` (a `CFRunLoop` on the main thread), never `dispatchMain()`:
  that drains the main queue off the main thread, and on macOS 26 and earlier `assumeIsolated`
  then traps (it crashed on SIGTERM, before restoring the mouse).
- Device settings are volatile: the mouse forgets them on every reconnect. Anything applied to
  it belongs in `Session.apply()`, which runs on adoption, reconnect, wake and reload.
- On SIGTERM/SIGINT, `Session.restore()` returns the mouse to native behaviour (wheels first).
  Nothing may be persisted on the device or receiver: they must work normally without mxd.
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
- The wheels are only diverted when mxd can post events (Accessibility). Diverting without it
  silences them.
- Permission checks are cached per process. The launchd-run daemon polls a child
  (`mxd permissions`) and restarts itself when a grant arrives (`Daemon.restartWhenGranted`).
- HID++ software IDs rotate per request so a late reply cannot complete a newer request.
- `mxd register` (and opening the app from the Finder, i.e. no arguments inside a bundle) writes
  `~/Library/LaunchAgents/<bundle id>.plist` pointing at its own binary and bootstraps it,
  booting out any running instance first (`LoginItem.swift`). Not `SMAppService`: without a
  Developer ID team, launchd pins its agents to the registering build ("needs LWCR update"), so a
  replaced app's agent fails to spawn with EX_CONFIG, and re-registering did not reliably clear it.
- Builds are signed with the `mxd` code-signing identity (self-signed, `scripts/make-cert.sh`).
  The permission grants are keyed to identifier plus certificate, which also holds on Macs that
  do not trust the certificate; an ad-hoc signature makes macOS drop them on every install.
  install.sh stops the agent before replacing the binary.
- Gatekeeper: launching a quarantined copy parks it at `_dyld_start` behind an on-screen dialog.
  On workshop, later launches at that path stayed parked even after clearing the flag and putting
  a fresh copy there (presumably until the dialog is answered). Clear the flag before the first
  launch.
- Some actions use undocumented interfaces: `CoreDockSendNotification` (it returns 0 even for
  unknown names, so failure is silent) and the navigation-swipe CGEvent fields. macOS 27 already
  stopped honouring the dock-swipe fields, which mxd does not use. After an OS upgrade, check them
  with `mxd action <name>`; README's "After a macOS upgrade" lists the keystroke fallbacks.
- Logi Options+ fights mxd over the mouse. Its agent (`com.logi.cp-dev-mgr`) is disabled on this
  machine; re-enabling it breaks mxd. The daemon logs an error at start if it sees any of its
  processes (`LogiOptions`); only this user's process names are readable, so a root-run updater
  goes unseen.
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per session; if
  the list cannot be read, the configured value is sent unchanged.

## Extending

- New action: a case in `Action`, a name in `Action.named`, handling in `SystemActions.perform`.
- New device feature: a wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, and a parse test in `Tests/HIDPPTests`.
- Per-app scroll settings: choose a different `ScrollEngine.Profile` when a burst starts.
- Scroll feel: `ScrollAcceleration` (curve) and `ScrollAnimator` (two-part easing) in
  `ScrollModel.swift`, covered by `ScrollModelTests`.
- Protocol references: Solaar (`hidpp20.py`), logiops, Mac Mouse Fix. `mxd probe` dumps the raw
  feature state for comparison.

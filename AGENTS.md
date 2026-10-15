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
  with it (its test checks shape, not values). Config changes apply on save (`ConfigWatcher`
  watches the file and its directory, reloading when the bytes change) or with
  `launchctl kill HUP gui/$UID/io.github.mblauberg.puremouse`, no rebuild. Never edit the live
  config to test: run a dev daemon against a copy.
- Other Macs: `./scripts/package.sh` builds the universal release zip. On a test Mac over SSH,
  drive the installed app with `puremouse register`/`unregister`. Over SSH nobody can answer a
  Gatekeeper dialog or grant permissions, so leave those to whoever is at the Mac. Machine-specific
  notes belong in the uncommitted `CLAUDE.local.md`.
- Releases: tag `vX.Y.Z` on a clean `main` (the bundle version is the tag without the `v`), run
  `./scripts/package.sh` on a Mac holding the `PureMouse` signing identity, and attach
  `.build/dist/PureMouse-X.Y.Z.zip` to a GitHub release with its SHA-256. A release signed by any
  other identity makes every user grant permissions again. CI (`.github/workflows/ci.yml`) builds,
  tests and bundles ad hoc on each push.
- The icon is an Icon Composer document, `assets/AppIcon.icon` (two SVG layers: body and wheel;
  the background is the system's light/dark fill, so macOS 26+ renders light, dark, clear and
  tinted variants). After changing it, run `./scripts/make-icon.sh` (needs Xcode 26+) and commit
  the compiled `Assets.car`, `AppIcon.icns` (macOS 14/15 fallback) and the README PNGs.
  `assets/MenuBarIcon.svg` is the same glyph as a monochrome template for a menu bar item, with
  wider gaps so it survives 16pt; keep the two in step.
- When behaviour changes, update the README's field tables and this file in the same change.

## Invariants

- `Sources/HIDPP` is protocol only (framing, transport, typed feature wrappers) and must stay
  free of policy. Applying config, performing actions and scrolling live in `Sources/puremouse`.
- `Sources/PureMouseKit` is shared with the menu bar app: the config model and its decoder
  (`Config`, `Action` and its `named` table, `Keystroke` parsing, `AnyKey`, the range-checked
  decode helper) and the status/control channel (`Companion.swift`, contract in
  `docs/companion.md`). Data only: no HID, no event posting, no `Log` (the decoder collects
  problems such as `unknownButtons` and the daemon logs them). `ConfigCheck.validate` is the real
  decoder, so the menu never writes a file the daemon would reject.
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
  stops adopting once `shuttingDown` or `paused` (`Daemon.accepting`). Pausing from the menu
  (`Control.paused`) restores and drops every session; nothing is adopted until those restores
  finish, even after a resume (`PauseGate`), and quitting waits for them (`Daemon.pausing`). A
  pause is never persisted.
- Every change to which controls are diverted, from `apply()` or capture, runs through one chain
  (`Session.enqueueDiversion`), one at a time and in the order asked, reading the wanted state as
  it runs; `restore()` drains the chain before releasing, and each write checks `finished`.
- The daemon reports to the menu bar app only through `status.json` (`StatusChannel`): call
  `statusChanged()` (Daemon) or `changed()` (Session) after anything in `Status` changes; writes
  are coalesced to one per main-queue turn. On shutdown, `running: false` is written last, after
  the mice are restored (`exitReporting`).
- Keep it light: no dependencies, and no AppKit or SwiftUI in the daemon or PureMouseKit (only
  `PureMouseMenu` may link them). Idle cost is zero CPU; the display link
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
  from the current config: after a reload that drops (or disables) `smoothScroll`, the
  replacement session inherits the flag and keeps it until its own apply has set the wheels
  native.
- Select by pressing (`Control.capture`) diverts every pressable, unbound control
  (`Session.beginCapture`) for at most `Daemon.captureDuration`; the first press goes to
  `onCapture` and performs nothing; a gesture held as capture starts is dropped, so letting it go
  does not click. Every way out (press, timeout, cancel, reload, pause) goes
  through `Daemon.endCapture`, which hands the extra controls back, each independently (one that
  fails waits for the next apply). They count in
  `divertedControls` until released, so `restore()` and a replacement session release them too.
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
- The same commands manage the menu bar app's agent (`io.github.mblauberg.puremouse.menu`) when
  the bundle has `Contents/Library/LoginItems/PureMouse Menu.app`; dev builds without it handle
  the daemon only. `menu off` is remembered by a `menu-hidden` file in the companion directory, so
  `register` keeps the icon hidden. The menu app runs these commands as its child, and booting
  out its agent kills its process group: `main` calls `setsid()` first, every command boots the
  menu agent out last (after removing its plist), and `register`/`menu on` leave an already
  loaded menu agent running when the menu app itself is the caller.
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
  `Sources/PureMouseKit/Config.swift`); give any new numeric field a range too. An unchecked
  value can overflow an `Int` or `Duration` conversion mid-session, and during a reload that crash
  comes after the old session has closed, so the mouse is never restored and launchd relaunches
  into the same crash.
- Events only route for features whose index is already resolved (`HIDPPDevice.feature(at:)`), so
  `Session.apply()` resolves the event-bearing ones (0x1B04, 0x1D4B, 0x1004 battery) first.
  Battery is read on each apply and then follows the 0x1004 broadcast events; it is
  informational and never fails an apply. Level bits are masked by getCapabilities (cleared
  when the mouse reports a percentage) and the highest wins, as in Linux.
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per mouse and
  inherited across reloads; if the list cannot be read, the configured value is sent unchanged.
  `cycleDPI` sets `Session.liveDPI`, which overrides `config.dpi` in `apply()`; `Daemon.reload`
  clears it only when `dpi` or `dpiPresets` changed.

## Extending

- New action: a case in `Action` and a name in `Action.named` (both in PureMouseKit), handling in
  `SystemActions.perform` (or `Session.perform` for device actions).
- New device feature: a wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, and a parse test in `Tests/HIDPPTests`.
- Per-app scroll settings: choose a different `ScrollEngine.Profile` when a burst starts.
- Scroll feel: `ScrollAcceleration` (curve) and `ScrollAnimator` (two-part easing) in
  `ScrollModel.swift`, covered by `ScrollModelTests`.
- Protocol references: Solaar (`hidpp20.py`), logiops, Mac Mouse Fix. `puremouse probe` dumps the
  raw feature state for comparison.

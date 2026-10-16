# PureMouse: agent notes

Read `README.md` first for what PureMouse does, then `docs/how-it-works.md` for its layout and
`docs/configuration.md` for the config. This file covers how to work on it safely.

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
- Menu bar app (`Sources/PureMouseMenu`): run `.build/debug/PureMouseMenu` alongside the installed
  agent, but point it away from the real files first: `PUREMOUSE_CONFIG` (config file),
  `PUREMOUSE_DAEMON` (the binary it runs for register/stop/menu commands; a stub script is fine)
  and `PUREMOUSE_COMPANION_DIR` (the status/control channel; a fixture `status.json` there stands
  in for the daemon). Without them it edits the live config and drives the installed agent. Debug
  builds also take `PUREMOUSE_DEV_PANE=<pane>`, `PUREMOUSE_DEV_MENU=1`,
  `PUREMOUSE_DEV_APPEARANCE=light|dark`, `PUREMOUSE_DEV_PICKER=<button>`,
  `PUREMOUSE_DEV_SHORTCUT=<button>` (Buttons pane) and `PUREMOUSE_DEV_APP=<bundle id>` (Apps pane;
  adds the app without writing) for screenshots (`DevHooks.swift`); `--login` launches it as
  launchd does (no Settings window). `PUREMOUSE_DEV_MENU=1` puts a plain backdrop under the menu,
  since its glass shows whatever is behind it. A window capture (`screencapture -l`) leaves out
  that blur, so the README's menu shots take the shape and shadow from one and the body from a
  screen capture of the same rect. Check its footprint with `footprint <pid>` before and after
  opening Settings.
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
- The icon is an Icon Composer document, `assets/AppIcon.icon`: a top-down mouse in three
  monochrome glass layers (buttons with the centre seam, palm, floating wheel), grey fills with
  light and dark specializations, on the system's light/dark background, so macOS 26+ renders
  light, dark, clear and tinted variants. After changing it, run `./scripts/make-icon.sh` (needs
  Xcode 26+ and `rsvg-convert`) and commit the compiled `Assets.car`, `AppIcon.icns` (macOS 14/15
  fallback), the README PNGs (also the About pane's icon) and `MenuBarIcon.pdf`.
  `assets/MenuBarIcon.svg` is the same mouse as an 18x18 pt template (alpha only; the wheel is a slot, gaps are 1-1.5 pt on the half-point grid
  so they stay crisp at 1x and 2x); it is plain clip and even-odd paths because rsvg rasterises
  SVG masks in the PDF. The menu bar app loads `MenuBarIcon.pdf`. Keep the two in step.
- When behaviour changes, update `docs/configuration.md`'s field tables and this file in the same
  change.

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
- Prefer SmartShift 0x2110 whenever present (the tested 3S path); only its absence selects
  Enhanced 0x2111. Enhanced writes always include mode, with torque 0 to leave torque unchanged.
  Haptic 0x19B0 is play-only, gated by its waveform capability mask: never write strength,
  enable flags or configuration (persistence is unknown). Cache haptic absence per session.
  Enhanced SmartShift may skip malformed/feature-error replies only; timeouts and transport
  failures must reach configure's retry handling. Feature summaries use already resolved
  indices after a successful apply, never extra adoption queries. Other mice remain labelled untested.
- On SIGTERM/SIGINT, `Session.restore()` returns the mouse to native behaviour (wheels first).
  Nothing may be persisted on the device or receiver: they must work normally without PureMouse.
- A session that is `finished` (closed or restored) must not touch the device again; the daemon
  stops adopting once `shuttingDown` or `paused` (`Daemon.accepting`). Pausing from the menu
  (`Control.paused`) restores and drops every session; nothing is adopted until those restores
  finish, even after a resume (`PauseGate`), and quitting waits for them (`Daemon.pausing`). A
  pause is never persisted.
- Device-action chains propagate tail cancellation through predecessors (`Session.chainedAction`),
  so an earlier action waiting for transport ownership cannot send after close/restore.
- Every change to which controls are diverted, and the wheels' diversion, from `apply()`, capture
  or a Universal Control handoff, runs through one chain (`Session.enqueueDiversion`), one at a
  time and in the order asked, reading the wanted state (`Handoff`, including `away`) as it runs
  (`SerialChain`). Each write checks `finished` right before it goes out, not only when the body
  starts; `close()` cancels the chain, and a replacement session's chain starts after the old
  one's end (`Inherited.diversionAfter`), so no retired write lands after a replacement's.
  `restore()` drains the chain before releasing. Handing inputs back tries each wheel and control
  on its own (`Independently.each`); one that fails stays counted (`wheelsMayBeDiverted`,
  `divertedControls`) for the next apply or `restore()`.
- The daemon reports to the menu bar app only through `status.json` (`StatusChannel`): call
  `statusChanged()` (Daemon) or `changed()` (Session) after anything in `Status` changes; writes
  are coalesced to one per main-queue turn. On shutdown, `running: false` is written last, after
  the mice are restored (`exitReporting`).
- Keep it light: no dependencies, and no AppKit or SwiftUI in the daemon or PureMouseKit (only
  `PureMouseMenu` may link them). Idle cost is zero CPU; the display link
  runs only while a scroll is gliding, never with `smoothingMs` 0 (`PixelCarry` posts at once).
- The menu bar app never opens HID devices: it edits the config file and talks to the daemon only
  through the companion channel and the daemon CLI (`docs/companion.md`). It must not poll: it
  wakes on notifications, file events and the daemon's process exit. Its Settings window and view
  tree are built when shown (each pane on its first visit); once Settings closes the process starts
  over (`Relaunch`): the agent's copy exits 75 for launchd to restart, since AppKit and SwiftUI keep
  about 35 MB otherwise. Never `exec` in place (LaunchServices then withholds the status item). The
  menu is rebuilt on open. Settings controls carry their own accessibility label where a `RowLabel`
  (title plus caption) leaves them unnamed. Shortcut specs are parsed and named by Kit's `Keystroke` only; the menu adds
  glyphs and spoken words.
- Notifications and the update check live in the menu app only (the daemon stays free of
  UserNotifications and the network). The low-battery notification (`BatteryAlert`,
  `Notifier`) is decided on each status the daemon writes, from the band already announced per
  mouse (keyed by status device id), kept in `battery-alerts.json` in the companion directory so a relaunch cannot repeat it;
  the first reading of a mouse after it connects (or this process starts) only records. It does not run while the icon is hidden. Permission
  is requested lazily (toggle on, or first notification); `UNUserNotificationCenter` needs a
  bundle, so a bare dev run posts nothing. "Check for Updates" (About pane, `UpdateCheck`) makes
  one GET of the latest GitHub release per press: no background checks.
- The DPI the menu and the Pointer pane show is the mouse's live value (a `cycleDPI` press
  changes it without touching the config), then the configured one; a change made in the pane
  shows until the mouse reports it (`DPIReading`).
- The menu bar app writes only the keys a control owns (`ConfigTree`) and keeps every other key,
  including unknown ones. It records edits as the keys they set and `ConfigFile.save` replays
  them onto the file as it is when saving, so a hand edit made meanwhile survives; with no
  pending edit nothing is written. It refuses to build on a file that does not parse or
  validate, and writes through `JSON.encode` (shortest decimals, sorted keys, whole and big
  numbers kept digit for digit), never `JSONSerialization`.
- The Buttons and Apps panes list a named button when a connected mouse reports it or the config
  binds it; with no report, those `NamedButton.listedByDefault` (not the MX Master 4's thumb panel)
  (`ButtonRows.named`). Haptic picker entries come from Kit's `HapticWaveform.allCases`; the menu
  only words them (`ActionCatalog.hapticLabel`).
- The Apps pane writes only `apps.<id>` keys (`AppSettings.swift`): each control's own key, removed
  for "Same as Everywhere" (an emptied app entry is pruned); an added app is not written until a
  setting is chosen. App icons and names load only for rows on screen (`AppIdentities`), and
  Applications is never listed (adding goes through an open panel or the running apps). A pane
  whose height changes while shown calls `AppController.refitSettings()`: a nested
  `NSHostingController` updates its `preferredContentSize` without telling the tab controller, so
  `SettingsTabs.refit()` copies it across.
- Settings shows no focus ring until the keyboard is used: windows, panes, the action picker and
  the shortcut sheet open with nothing focused (the picker's search takes the first keystroke).
  Check with keyboard navigation (`AppleKeyboardUIMode`) both on and off.

## Easy to break

- Scroll events carry whole pixels only. Setting the fractional point-delta fields replaces the
  integer delta with its truncation and silently loses distance.
- Scroll events have no gesture phases. Phased horizontal scrolls make browsers swipe back and
  forward.
- Synthetic scrolls skip the system's natural-scrolling flip, so `ScrollEngine` applies it,
  re-reading the setting at the start of each burst.
- The wheels are only diverted when PureMouse can post events (Accessibility). Diverting without it
  silences them. Both are diverted when any scope (global or an app) scrolls smoothly; the thumb
  wheel alone when any scope gives it actions (`Session.applyWheels`). Where the scope in effect
  does not scroll smoothly, the diverted wheel still scrolls, with zero smoothing.
- Per-app settings (`apps`) are merged onto the global ones by the Kit decoder (`Config+Apps.swift`,
  `Config.AppSettings`); only `buttons`, `thumbWheel` (not `inverted`) and `smoothScroll` are
  per-app. The app is looked up only when some app sets that section (`Session.appButtons`,
  `appThumbWheel`, `appProfiles`): the frontmost app at each press, the app under the pointer when a
  scroll burst (`ScrollEngine.profileForBurst`) or thumb-wheel movement starts. `ForegroundApp`
  does the lookups, AppKit-free and on demand; the Universal Control work reuses it. Every control
  bound in any scope is diverted; pressed where nothing binds it, the wheel press, back and
  forward post their ordinary click (`NativeButton`), released in kind. Held buttons
  (`HeldButtons`) are dropped, native clicks released, whenever the mouse's own release may not
  come: link down, reconnect, reload, pause and quit (`Session.dropHeld`). A per-app `thumbWheel`
  keeps the global direction and step it leaves out.
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
- Universal Control: while the pointer is on another Mac, `Session.away` leaves the wheels and
  every diverted control native (DPI, SmartShift and the rest stay applied), so macOS forwards them;
  apply, capture and new or replacement sessions all honour it (`Daemon.handingOff`, passed in
  `Session.Inherited.away`). The signal is undocumented: the Darwin notification
  `user.uid.<uid>.com.apple.universalcontrol.inputstate` (found in Logi Options+'s agent), whose
  state was observed on macOS 27 as 0x2 pointer away, 0x3 keyboard followed, 0x1 pointer back with
  the keyboard still remote, 0x0 home (`UniversalControlState`). Verify after OS upgrades: register
  with `notify_register_dispatch` and print `notify_get_state` on each post while crossing (a
  ten-line Swift script, `import notify`), and check the log's "pointer moved to another Mac" lines.
  Going away also stops any glide and drops held gesture state, and ends a capture.
- Permission checks are cached per process. The launchd-run daemon polls a child
  (`puremouse permissions`) and restarts itself when a grant arrives (`Daemon.restartWhenGranted`).
- HID++ software IDs rotate per request so a late reply cannot complete a newer request.
- An endpoint that does not answer is retried after 1, 2, 4 and 8 s (`Daemon.adoptRetrying`,
  `Backoff.adoption`), one retry per endpoint whether attach, a connection notification, resume,
  wake or reload started it; pause, detach and shutdown cancel it. After that a receiver slot is
  left to its connection notification, so idle cost stays zero. A Bluetooth mouse has no
  notifications, so it is then tried once a minute (`Backoff.bluetooth`) until it answers. A slot
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
  unknown names, so failure is silent), the navigation-swipe CGEvent fields,
  `CGSGetSymbolicHotKeyValue` (the user's Spaces shortcuts, read only; Ctrl+arrow when off) and
  `IOHIDPostEvent` for media keys (deprecated, so looked up with `dlsym`; `AuxKey`).
  `ForegroundApp.frontmost` uses SkyLight's `_SLPSGetFrontProcess` with `GetProcessPID`, falling
  back to the frontmost window's owner; the Accessibility focused-application attribute was 8-40 ms
  or failed outright, so it is not used. macOS 27 already
  stopped honouring the dock-swipe fields, which PureMouse does not use. After an OS upgrade, check
  them with `puremouse action <name>`; `docs/troubleshooting.md` ("After a macOS upgrade") lists
  the keystroke fallbacks.
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
  Battery is read on each apply and then follows broadcast events; 0x1000 is read only
  as a fallback when 0x1004 is absent; resolve/select it before configuration writes and inherit
  that selection across reloads. Only the selected fallback's broadcasts are used. It is
  informational and never fails an apply. Level bits are masked by getCapabilities (cleared
  when the mouse reports a percentage) and the highest wins, as in Linux.
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per mouse and
  inherited across reloads; if the list cannot be read, the configured value is sent unchanged.
  `cycleDPI` sets `Session.liveDPI`, which overrides `config.dpi` in `apply()`; `Daemon.reload`
  clears it only when `dpi` or `dpiPresets` changed, and `Control.useConfiguredDPI` clears it on
  request (`AppModel.setDPI` sends it, since choosing the saved value changes nothing on disk).

## Extending

- New named button: keep `Config.Button` and the menu's `NamedButton` in step (names and CIDs).
- New action: a case in `Action` and a name in `Action.named` (both in PureMouseKit), handling in
  `SystemActions.perform` (or `Session.perform` for device actions).
- New device feature: a wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, and a parse test in `Tests/HIDPPTests`.
- Per-app settings: a new per-app section needs a case in `Config.appSections`, decoding on top of
  the global value in `Config.decodeApps`, a `sets…` flag, and its lookup at the moment it applies.
- Thumb-wheel actions: `Config.ThumbWheel.presets` (Kit) names action pairs; `ThumbStepper` counts
  rotation into steps (remainder kept, reset at each movement's start), paced per action
  (`ThumbStepper.pacing`: media keys free, shortcuts 50 ms, zoom 40 ms, animated actions 300 ms
  with the turns between discarded).
- Thumb wheel presets in Settings: `ThumbWheelChoice` (`Logic/ThumbWheel.swift`) lists Kit's
  presets in `presetOrder`, with a label each; `ThumbWheelState` mirrors Kit's
  `Config.ThumbWheel.init(_:base:)` and a test checks it against the decoder. App suggestions are
  `AppSuggestion.table`.
- Scroll feel: `ScrollAcceleration` (curve) and `ScrollAnimator` (two-part easing) in
  `ScrollModel.swift`, covered by `ScrollModelTests`.
- Protocol references: Solaar (`hidpp20.py`), logiops, Mac Mouse Fix. `puremouse probe` dumps the
  raw feature state for comparison.

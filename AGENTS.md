# PureMouse: agent notes

Read `README.md` first for what PureMouse does, then `docs/how-it-works.md` for its layout and
`docs/configuration.md` for the config. Architecture decisions, with their status and the
alternatives rejected, are in `docs/adr/`: cite them, and amend the record when a change alters
one. This file covers how to work on it safely.

## Workflow

- Build and test: `swift build && swift test`. Device behaviour is tested against `HIDPPTesting`
  fakes (`FakeDevice`, `FakeTransport`) built from `puremouse probe` dumps in `Tests/Fixtures/probe`,
  so the probe's output format is a fixture contract. Real mice still need a live check.
- Live check: `.build/debug/puremouse probe` is read-only and safe alongside the daemon (it uses its
  own HID++ software IDs). To run a dev build, stop the agent first (two daemons fight over the
  mouse) with `/Applications/PureMouse.app/Contents/MacOS/puremouse unregister`, then run
  `.build/debug/puremouse --verbose run ./config.example.json`. A terminal-run daemon uses the
  terminal's permissions and never restarts itself. Finish with `./scripts/install.sh`, which
  rebuilds, re-signs and restarts the agent, and check `~/Library/Logs/PureMouse.log`.
  The daemon owns that file: `run` attaches stderr to it unless stderr is a terminal (`LogFile`),
  and rotates it to `PureMouse.log.1` past `Log.rotateAt` (1 MiB). The agent plists set no
  `StandardErrorPath`, and the menu bar app keeps no log. Any non-terminal stderr counts, so a dev
  run piped or redirected also writes to that file. Only the daemon's own lines are counted, so
  `run` commands get /dev/null for stdout and stderr (`SystemActions.shell`); a failure is logged
  once.
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
  opening Settings, or reproduce the published figures with `scripts/measure-menu.sh` on a spare
  Mac (never the one whose PureMouse you use; `docs/development.md`, "Footprint rig"). Its release
  build carries `DevHooks` only with `-DDEVHOOKS`, and acts only when `PUREMOUSE_COMPANION_DIR` is
  set, which also gives the doorbells names of their own (`Companion.doorbell`), so a debug build
  with `PUREMOUSE_COMPANION_DIR` set no longer hears the installed daemon's bell.
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
  `PUREMOUSE_SIGN_IDENTITY=PureMouse ./scripts/package.sh` on a Mac holding that identity (the
  identity order is in `docs/development.md`, Signing), and attach
  `.build/dist/PureMouse-X.Y.Z.zip` to a GitHub release with its SHA-256. A release signed by any
  other identity makes every user grant permissions again. CI (`.github/workflows/ci.yml`) builds,
  tests and bundles ad hoc, verifies the signatures, checks the size budget
  (`scripts/size-budget.env`) and runs `scripts/tests/run.sh` on each push to `main` and each pull
  request; its actions are pinned to full SHAs.
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
  decode helper), the `FileLock` both sides take, and the status/control channel
  (`Companion.swift`, contract in `docs/companion.md`). Data only: no HID, no event posting, no `Log` (the decoder collects
  problems such as `unknownButtons` and the daemon logs them). `ConfigCheck.validate` is the real
  decoder, so the menu never writes a file the daemon would reject. A config change must keep
  `ConfigGoldenTests` identical, or regenerate it on purpose. Before 1.0 nothing is kept
  for backward compatibility: the menu and daemon ship together, and config, status and control
  formats change freely (say so in the release notes). Add no frozen readers, fallbacks for older
  versions, legacy shims or migrations.
- All HID and HID++ work runs on the main actor. IOKit and CoreVideo callbacks hop to it
  (`MainActor.assumeIsolated` / `DispatchQueue.main`); keep it that way. The process serves the
  main queue with `runMainLoop()` (a `CFRunLoop` on the main thread), never `dispatchMain()`:
  that drains the main queue off the main thread, and on macOS 26 and earlier `assumeIsolated`
  then traps (it crashed on SIGTERM, before restoring the mouse).
- Device settings are volatile: the mouse forgets them on every reconnect. Anything applied to
  it belongs in `Session.apply()`, which runs on adoption, reconnect, wake and reload. A newer
  `Session.configure()` supersedes one under way; only an offline mouse's other events
  (`reconfigureIfOffline`) defer to a running one, and start one at most once per 30 s.
- Feature absence is cached per endpoint in `HIDPPDevice` (`knownPresence`; only a definite
  index-zero answer counts), while "missing feature" log flags stay per session.
- The primary clicks 0x0050/0x0051 (`Config.reservedControls`) are never bound or diverted: the
  decoder drops them with a warning and `Session.isDivertable` excludes them from binding,
  capture and the stale-diversion scan.
- Prefer SmartShift 0x2110 whenever present (the tested 3S path); only its absence selects
  Enhanced 0x2111. Enhanced writes always include mode, with torque 0 to leave torque unchanged.
  Haptic 0x19B0 is play-only, gated by its waveform capability mask: never write strength,
  enable flags or configuration (persistence is unknown). Log haptic absence once per session.
  It is looked up only by a haptic action, never by apply, so `capabilities.haptics` stays unknown
  until one runs; an action's lookup that changes the capabilities publishes them
  (`Session.capabilitiesMayHaveChanged`).
  Enhanced SmartShift may skip malformed/feature-error replies only; timeouts and transport
  failures must reach configure's retry handling. Feature summaries use already resolved
  indices after a successful apply, never extra adoption queries. The MX Master 3S is the
  development mouse; the README lists the others by the features they report, and the logs still
  call Enhanced-only mice untested.
- On SIGTERM/SIGINT, `Session.restore()` returns the mouse to native behaviour (wheels first). Each
  of its requests times out after `Session.restoreTimeout` (400 ms), and quitting waits long enough
  for every one of them to (`Daemon.shutdownDeadline`, 2-5 s), counting the restores of a pause
  still under way (`Daemon.restoreSteps`), so a missed reply cannot leave the rest diverted. Nothing
  may be persisted on the device or receiver: they must work normally without PureMouse.
- A session that is `finished` (closed or restored) must not touch the device again; the daemon
  stops adopting once `shuttingDown` or `paused` (`Daemon.accepting`). Pausing from the menu
  (`Control.paused`) restores and drops every session; nothing is adopted until those restores
  finish, even after a resume (`PauseGate`), and quitting waits for them (`Daemon.pausing`). A
  pause is never persisted.
- Device actions (`cycleDPI`, `toggleScrollMode`, haptics) and `apply()`'s DPI and SmartShift
  writes run on one chain (`Session.deviceActions`, a `SerialChain`), one at a time, each reading
  what is wanted (`liveDPI`, `scrollMode`) as it runs, so a press mid-apply is neither undone nor
  overwritten. `close()` and `restore()` cancel it (`Session.finish`), so an action waiting for
  transport ownership cannot send after them.
- Every change to which controls are diverted, and the wheels' diversion, from `apply()`, capture
  or a Universal Control handoff, runs through one chain (`Session.enqueueDiversion`), one at a
  time and in the order asked, reading the wanted state (`Handoff`, including `away`) as it runs
  (`SerialChain`). Each write checks `finished` right before it goes out, not only when the body
  starts; `close()` cancels the chain, and a replacement session's chain starts after the old
  one's end (`Inherited.diversionAfter`), so no retired write lands after a replacement's.
  `restore()` cancels and drains the chain before releasing. Handing inputs back tries each wheel and control
  on its own (`Independently.each`); one that fails stays counted (`wheelsMayBeDiverted`,
  `divertedControls`) for the next apply or `restore()`.
- The daemon reports to the menu bar app only through `status.json` (`StatusChannel`): call
  `statusChanged()` (Daemon) or `changed()` (Session) after anything in `Status` changes; writes
  are coalesced to one per main-queue turn. On shutdown, `running: false` is written last, after
  the mice are restored (`exitReporting`).
- Keep it light: no dependencies, and no AppKit or SwiftUI in the daemon or PureMouseKit (only
  `PureMouseMenu` may link them). Idle cost is zero CPU, with one bounded exception: while a
  permission needed now is missing, a `puremouse permissions` child runs after 2, 4, 8, 16 and
  32 s and then once a minute, until 10 minutes after the latest start, wake, reload, control
  change or Bluetooth attach (`Daemon.pollPermissions`). The display link runs only while a
  scroll is gliding, never with `smoothingMs` 0 (`PixelCarry` posts at once).
- The menu bar app never opens HID devices: it edits the config file and talks to the daemon only
  through the companion channel and the daemon CLI (`docs/companion.md`). Its logic that needs no
  AppKit or SwiftUI lives in `Sources/PureMouseAppSupport` (config editing and saving,
  `Locations`, status words), tested in `Tests/PureMouseAppSupportTests`; keep UI frameworks out
  of it. It must not poll: it wakes on notifications, file events and the daemon's process exit.
  Its Settings window and view tree are built when shown (each pane on its first visit); once
  Settings closes the process starts over (`Relaunch`): the agent's copy exits 75 for launchd to
  restart, since AppKit and SwiftUI keep about 25 MB otherwise (against about 10 MB fresh;
  `docs/companion.md`, Footprint). Never `exec` in place (LaunchServices then withholds the status
  item). The menu is rebuilt on open. Settings controls carry their own accessibility label where a
  `RowLabel` (title plus caption) leaves them unnamed. Shortcut specs are parsed and named by Kit's
  `Keystroke` only; the menu adds glyphs and spoken words.
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
  them onto the file as it is when saving, so a hand edit made meanwhile survives (a new object is
  recorded key by key so it merges with one added by hand; an emptied one is removed whole, and
  removing a key that is not there is a no-op, so it never prunes an ancestor); with no
  pending edit nothing is written. It refuses to build on a file that does not parse or
  validate, and writes through `JSON.encode` (shortest decimals, sorted keys, whole and big
  numbers kept digit for digit), never `JSONSerialization`. Only Reset All Settings and Restore
  Last Working replace the whole file, and they keep the previous one as `config.json.bak`
  first (`ConfigFile.replace`; nothing kept for no file or `{}`); Open Config File only creates a
  missing file (`createIfMissing`). Every one of these writes runs under `flock` on
  `config.json.lock` beside the resolved config, and `control.json` writes under
  `control.json.lock`, changing only the fields that request sets; the daemon's startup delete of
  it takes the same lock (`docs/companion.md`).
- The Buttons and Apps panes list a named button when a connected mouse reports it or the config
  binds it; with no report, those `NamedButton.listedByDefault` (not the MX Master 4's thumb panel)
  (`ButtonRows.named`). Haptic picker entries come from Kit's `HapticWaveform.allCases`; the menu
  only words them (`ActionCatalog.hapticLabel`).
- The Apps pane writes only `apps.<id>` keys (`AppSettings.swift`): each control's own key, removed
  for "Same as Everywhere" (an emptied app entry is pruned); an added app is not written until a
  setting is chosen (its row says so until Settings closes). Names are looked up without icons
  (`AppIdentities`); an icon loads when its frame meets the scroll view's visible bounds (`AppIcon`;
  a grouped form builds every row, so `onAppear` is not enough, and macOS 14 lacks
  `onScrollVisibilityChange`), and Applications is never listed (adding goes through an
  open panel or the running apps). A pane is no taller than the screen (`LazyPane.fitted`). A pane
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
  does not scroll smoothly, the diverted wheel still scrolls, with zero smoothing. Only wheels the
  mouse has are taken over, each through its `Session.Wheel.feature`. Smooth scrolling needs the
  main wheel's (0x2121 for now; `capabilities.smoothScroll` follows it); a mouse without it
  scrolls natively, with one info line per session (`Session.smoothScrollUnsupported`).
- Per-device settings (`devices.<key>`, `Config+Devices.swift`) are resolved by the Kit decoder:
  each entry is decoded on top of the top level, then `apps` on top of that, so precedence is top
  level, device, app. The key is `m` plus the 0x0003 model ID, else `p` plus the product ID
  (`Config.deviceKey`, read at adoption by `Identification`; a 0x0003 timeout leaves it nil and the
  top level applies). A receiver mouse keyed by its product but adopted before its slot was
  announced gets its key, and a session on that key's settings, when it next links up
  (`Daemon.sessionSlotAnnounced`). The daemon hands each session `config.forDevice(deviceKey)` at
  adoption and on reload; permission decisions cover every scope (`Config.everyScope`,
  `Daemon.postsEvents`). The adoption gate (`Daemon.gates`) checks every bound control
  (`Config.everyBoundControl`) before identification, then the mouse's own settings. Nothing
  is special-cased by model or product ID: a session uses what its mouse reports, and a bound
  control it lacks is a debug line once per session.
- Per-app settings (`apps`) are merged onto the global ones by the Kit decoder (`Config+Apps.swift`,
  `Config.AppSettings`); only `buttons`, `thumbWheel` (including `reversed`, not `inverted`) and
  `smoothScroll` are per-app. The app is looked up only when some app sets that section (`Session.appButtons`,
  `appThumbWheel`, `appProfiles`): the frontmost app at each press of a control some app names
  (`AppSettings.buttons`), the app under the pointer when a
  scroll burst (`ScrollEngine.profileForBurst`) or thumb-wheel movement starts. `ForegroundApp`
  does the lookups, AppKit-free and on demand; the Universal Control work reuses it. Every control
  bound in any scope is diverted; pressed where nothing binds it, the wheel press, back and
  forward post their ordinary click (`NativeButton`), released in kind. Held buttons
  (`HeldButtons`) are dropped, native clicks released, whenever the mouse's own release may not
  come: link down, reconnect, reload, pause and quit (`Session.dropHeld`). A per-app `thumbWheel`
  keeps the global `reversed` and step it leaves out. The thumb wheel's `inverted` (global) flips
  its scrolling only; actions follow `reversed` of the scope settled at movement start
  (`Session.thumbSettings`), never `inverted` or natural scrolling.
- `restore()` decides whether to hand the wheels back from `Session.wheelsMayBeDiverted`, not
  from the current config: after a reload that drops (or disables) `smoothScroll`, the
  replacement session inherits the flag and keeps it until its own apply has set the wheels
  native.
- Select by pressing (`Control.capture`) diverts every pressable, unbound control
  (`Session.beginCapture`) of every mouse, or only those whose key matches `capture.device`
  (`Daemon.targets`), for at most `Daemon.captureDuration`; the first press goes to
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
  (`puremouse permissions`) and restarts itself when a grant arrives (`Daemon.pollPermissions`),
  only for permissions needed now (`Permissions.needed`: Accessibility when anything is bound or
  the wheels may be taken over; Input Monitoring with a Bluetooth mouse or when opening HID
  devices failed), and until `Daemon.permissionPollLength` (10 min) after the latest start, wake,
  reload, control change or Bluetooth attach; each of those starts or extends it. Without Input
  Monitoring a Bluetooth mouse is not retried after its first try.
- HID++ software IDs rotate per request so a late reply cannot complete a newer request. A
  cancelled request fails at once instead of holding the endpoint until its timeout. Only events
  reach `onEvent` (`Report.isEvent`): software ID 0, or a short HID++ 1.0 notification (sub-ID
  0x40-0x7F); a long report at those indices with another software ID is another program's reply.
- A slot whose ping gets a HID++ 1.0 answer (invalid sub-ID) is ignored, like a keyboard, and
  not retried (`Daemon.adoption(for:)`).
- A freshly adopted mouse (`Inherited.fresh`) is scanned once for temporary diversions a previous
  process left (`Session.scanStaleDiversions`) and releases those not bound; a persistent diversion
  (Logi Options+) is never written. A timeout keeps the scan pending, across reloads too; a device
  error skips that control.
- An endpoint that does not answer is retried after 1, 2, 4 and 8 s (`Daemon.adoptRetrying`,
  `Backoff.adoption`), one retry per endpoint whether attach, a connection notification, resume,
  wake or reload started it; pause, detach and shutdown cancel it. After that a receiver slot is
  left to its connection notification, so idle cost stays zero. A Bluetooth mouse has no
  notifications, so it is then tried once a minute (`Backoff.bluetooth`) until it answers. Turning
  on a receiver's connection notifications is retried the same way (`Daemon.retryNotifications`),
  then again on wake and resume; pause, detach and shutdown cancel it. When a notification carries a
  different wireless product ID from the one known for the slot (a new device paired into it), the
  slot's session is closed as on a disconnect and the newcomer adopted on a fresh `HIDPPDevice`, so
  no feature index, DPI list or state carries over (`Daemon.replaceEndpoint`); an ignored slot is
  identified again, and an identification of the old endpoint that finishes afterwards is discarded.
  The first announcement after attach only records the product.
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
- `LoginItem` is the policy (order above, `menu-hidden`, the caller's own agent) and talks to a
  `LoginService` (`LoginService.swift`; `LaunchdAgentService` is the launch agents, which owns the
  plist definitions and `launchctl`, and its `stop` holds the wait for the old instance to finish
  restoring the mouse). The seam names jobs by what to run, never by plist. `LoginItemTests` drives
  the policy against a fake and `LaunchdAgentServiceTests` the mechanism against a scripted
  `launchctl`. Every mutating command holds `lifecycle.lock` in the companion directory. "Starts at login" and "running now" are separate axes:
  `login on|off` register or unregister without loading or booting out, `start` starts what has no
  process (bootstrap if not loaded, kickstart if loaded idle with this copy's executable, otherwise bootout and bootstrap) and refreshes a registered job's
  plist first, without registering anything (an unregistered job runs from a plist under the
  companion directory that launchd does not load at login), `stop` boots out and keeps the registration
  (table in `docs/companion.md`). `puremouse login-status` prints `LoginStatus` (Kit) as JSON, and
  the menu reads "starts at login" from it, not from a plist file.
- Builds are signed by `scripts/sign-bundle.sh`: inside out from `scripts/lib.zsh`'s `components`
  (a new nested bundle is one more entry), no `--deep`, always the hardened runtime, with the
  identity `signing_identity` picks (the order is in `docs/development.md`, Signing). The
  permission grants are keyed to identifier plus certificate, which also holds on Macs that do not
  trust the certificate; an ad-hoc signature makes macOS drop them on every install.
  `scripts/verify-bundle.sh` checks every component and every architecture of it. install.sh
  stops the agent before replacing the binary.
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
  `Session.apply()` resolves the event-bearing ones (0x1B04, 0x1D4B, 0x1004 battery) first. Battery
  is read on each apply and then follows broadcast events; 0x1000 is read only as a fallback when
  0x1004 is absent; resolve/select it before configuration writes and inherit that selection across
  reloads. Only the selected source's broadcasts are used (0x1004 events, or legacy 0x1000 broadcast
  events when it was selected). It is informational and never fails an apply. Level bits are masked
  by getCapabilities (cleared when the mouse reports a percentage) and the highest wins, as in
  Linux.
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per mouse and
  inherited across reloads; if the mouse answers the list request with an error, the configured
  value is sent unchanged, while a timeout fails the apply so configure retries.
  `cycleDPI` sets `Session.liveDPI`, which overrides `config.dpi` in `apply()`; `Daemon.reload`
  clears it only when that mouse's resolved `dpi` or `dpiPresets` changed (`Daemon.keepsLiveDPI`),
  and `Control.useConfiguredDPI` clears it on request, for every mouse or those whose key is
  `Control.device` (`AppModel.setDPI` sends it, since choosing the saved value changes nothing on
  disk). A snapped DPI is logged once per mouse (`DeviceState.snapLogged`), not per reload.

## Extending

- New named button: keep `Config.Button` and the menu's `NamedButton` in step (names and CIDs).
  Add the control's display name to `ControlNames` (Kit) too.
- New action: a case in `Action` and a name in `Action.named` (both in PureMouseKit), handling in
  `SystemActions.perform` (or `Session.perform` for device actions).
- New device feature: a wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, a parse test in `Tests/HIDPPTests`, its
  behaviour in `FakeDevice` and its readback in a probe fixture.
- Per-app settings: a new per-app section needs a case in `Config.appSections`, decoding on top of
  the global value in `Config.decodeApps`, a `sets…` flag, and its lookup at the moment it applies.
  Every config section decodes on a `base` (its `init(_:base:)`); a new section takes one, keeps
  its range checks and adds cases to the golden decode test (`ConfigGoldenTests`).
- Per-device settings: a new per-device section needs a case in `Config.deviceSections` and
  decoding in `Config.decodeSections`, the one layering point: the top level decodes its sections
  there, and each device entry decodes its own there on top of the top level's.
- Thumb-wheel actions: `Config.ThumbWheel.presets` (Kit) names action pairs; `ThumbStepper` counts
  rotation into steps (remainder kept, reset at each movement's start), paced per action
  (`ThumbStepper.pacing`: media keys free, shortcuts 50 ms, zoom 40 ms, animated actions 300 ms
  with the turns between discarded).
- Thumb wheel presets in Settings: `ThumbWheelChoice` (`PureMouseAppSupport/ThumbWheel.swift`) lists Kit's
  presets in `presetOrder`, with a label each; `ThumbWheelState` mirrors Kit's
  `Config.ThumbWheel.init(_:base:)` and a test checks it against the decoder. App suggestions are
  `AppSuggestion.table`.
- Scroll feel: `ScrollAcceleration` (curve) and `ScrollAnimator` (two-part easing) in
  `ScrollModel.swift`, covered by `ScrollModelTests`.
- Protocol references: Solaar (`hidpp20.py`), logiops, Mac Mouse Fix. `puremouse probe` dumps the
  raw feature state for comparison.

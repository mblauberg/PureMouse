# How it works

PureMouse finds Logitech receivers and Bluetooth mice through IOKit and speaks HID++ 2.0 to them.
It diverts the buttons and wheels you configure, so their events come to PureMouse instead of
macOS, and posts the matching system events in their place.

The decisions behind this design, and the alternatives rejected, are recorded in
[`docs/adr/`](adr/README.md).

## Two processes

`PureMouse.app` holds two programs:

- **The daemon** (`Contents/MacOS/puremouse`) does all the work. It is the only process that
  talks to the mouse, and the only one that needs Accessibility and Input Monitoring. It has no
  window and links no UI framework.
- **The menu bar app** (`Contents/Library/LoginItems/PureMouse Menu.app`) shows status and opens
  Settings. It needs no permissions and never opens a device.
- **The Settings helper** (`Contents/Helpers/PureMouse Settings.app`) is the Settings window, as an
  app of its own that runs only while the window is open. It edits the config.

Either runs without the other: with the menu bar app quit, or its icon hidden, the mouse behaves exactly as
configured. They talk through two small JSON files and a Darwin notification after each write, so
neither polls. [companion.md](companion.md) is the contract.

launchd runs both from login agents the daemon writes itself, so a replaced app keeps working
without a Developer ID. `LoginItem` decides what to start, stop or register and in what order; a
`LoginService` (launch agents) does it, which keeps the policy testable and lets another
mechanism replace launchd ([ADR 0018](adr/0018-login-service-seam.md)). Starting at login and
running now are separate: `login on|off` change the first, `start` and `stop` the second.

## Keeping the mouse in step

The mouse forgets every setting PureMouse gives it whenever it sleeps, reconnects or switches
between a receiver and Bluetooth. PureMouse reapplies them on every reconnect, after the Mac wakes,
when the mouse comes back to this Mac from another and on each config reload, within 2 seconds of
the mouse answering ([Sessions](#sessions)), and says so when it could not.

Which mouse it is decides which settings apply (a `devices` entry on top of the top level). If the
mouse does not answer when asked who it is, it gets the top-level settings meanwhile, and is asked
again after each configure until it answers, then switches to its own entry. Nothing is polled.

On quit or logout it hands the wheels and buttons back to the mouse first. Nothing is stored on
the mouse or receiver, so they behave normally on any other computer.

## Universal Control

Universal Control forwards only native mouse input to another Mac, so scrolls and button presses
PureMouse diverts would not reach it. When the pointer crosses to another Mac, macOS posts an
undocumented per-user Darwin notification (`user.uid.<uid>.com.apple.universalcontrol.inputstate`);
its state has bit 0x2 set while the pointer is away and 0x1 while the keyboard is. PureMouse
watches it (`UniversalControlWatcher`, no polling) and, while the pointer is away, hands the wheels
and diverted buttons back to macOS, keeping DPI and the other settings. When the pointer returns it
diverts them again. `universalControl.handOff: false` turns this off.

The notification was found in Logi Options+'s agent. Its state was observed on macOS 27 as 0x2
pointer away, 0x3 keyboard followed, 0x1 pointer back with the keyboard still remote, and 0x0 home
(`UniversalControlState`). Verify it after each OS upgrade: a ten-line Swift script (`import
notify`) that registers with `notify_register_dispatch` and prints `notify_get_state` on each post
while crossing, and the log's "pointer moved to another Mac" lines.

## Which devices and features

A device is adopted if it says it is a mouse or trackball (0x0005), whatever the config binds, or
has adjustable DPI (0x2201, or 0x2202 on mice such as the G Pro X 2 Superstrike, which have no
0x2201); one that reports no type needs a control list (0x1B04) (`Daemon.gates`). Keyboards,
numpads, presenters, remotes, touchpads and receivers report a control list too, so that alone
does not qualify them. A slot whose ping gets a HID++ 1.0 answer (invalid sub-ID) is ignored, like
a keyboard, and not retried (`Daemon.adoption(for:)`). Each feature a mouse reports is then used
and nothing else is asked. Nothing is special-cased by model or product ID: a session uses what its
mouse reports, and a bound control it lacks is a debug line once per session.

SmartShift goes through 0x2110 whenever present (the tested MX Master 3S path); only its absence
selects Enhanced 0x2111, whose writes always include the mode, with torque 0 to leave torque
unchanged. Haptics (0x19B0) is play-only, gated by its waveform capability mask: PureMouse never
writes strength, enable flags or configuration, since whether they persist is unknown. The MX
Master 3S is the development mouse; [Supported mice](supported-mice.md) lists the others by the
features they report, and the log still calls Enhanced-only mice untested.

DPI goes through 0x2201, else 0x2202. The value is snapped to the sensor's list and read back. If
the mouse reads back something else, as a G305 in onboard mode does (its profile, 0x8100, owns the
resolution), DPI is reported as not controllable and the log says so once. PureMouse never writes
0x8100. A battery is read through 0x1004, else 0x1000, else 0x1001; the last gives a level only,
never a percentage.

### Deferred features

Not used, and why:

- 0x2205 (pointer speed, the MX Ergo's): whether a write survives a power cycle is unestablished,
  and PureMouse writes nothing a mouse keeps.
- 0x2120 (a flag-only wheel mode with no diversion): it cannot hand wheel input to PureMouse.
- 0x8100 (onboard profiles): persistent by design.
- 0x1001 percentages, and the Ergo's persistent control diversion (0x71 flag): only the temporary
  bit is ever set.

## Smooth scrolling

With smooth scrolling on, the wheels report raw movement to PureMouse, which accelerates it and
spreads it across display frames. A display link runs only while a scroll is gliding, so an idle
mouse costs no CPU. Thumb-wheel actions (volume, zoom, tabs and the rest) take over the thumb wheel
alone, even with smooth scrolling off; where the thumb wheel scrolls, it then scrolls without the
glide.

A notched wheel (0x2130, as on the Signature Plus M750 and the MX Ergo) reports whole notches
once PureMouse asks for them; each notch becomes the same per-notch distance a 0x2121 notch is
(40 px) and glides the same way. Asking is a temporary reporting bit, so the wheel is native again
whenever PureMouse lets go or the mouse reconnects, and the mouse is never given a persistent
setting. When a mouse has both features, 0x2121 is the wheel.

PureMouse posts plain continuous pixel scrolls without trackpad gesture phases, which would make
browsers swipe back and forward. Scroll events carry whole pixels only: setting the fractional
point-delta fields replaces the integer delta with its truncation and silently loses distance.
Synthetic scrolls skip the system's natural-scrolling flip, so `ScrollEngine` applies it itself,
re-reading the setting at the start of each burst.

The wheels are diverted only when PureMouse can post events (Accessibility); diverting without it
silences them. Both are diverted when any scope (global or an app) scrolls smoothly, and the
thumb wheel alone when any scope gives it actions (`Session.applyWheels`). Where the scope in effect
does not scroll smoothly, a diverted wheel still scrolls, with zero smoothing. Only the wheels a
mouse has are taken over, each through its `Session.Wheel.feature`; a new wheel feature is a `Wheel`
case, not a second list. Smooth scrolling needs a main wheel, 0x2121 else 0x2130
(`Wheel.mainWheels`, which `capabilities.smoothScroll` follows); a mouse with neither scrolls
natively, with one info line per session (`Session.smoothScrollUnsupported`). 0x2130 is diverted with
its temporary reporting bit only and handed back like the rest (`restoreSteps` counts it). It is read
back after diverting: a wheel that does not report diverted stays native and is not offered smooth
scrolling (`Session.notchedRefused`). The display link never runs with `smoothingMs` 0
(`PixelCarry` posts at once).

## Per-app settings

Buttons, the thumb wheel and smooth scrolling can differ per app. Nothing watches app switches:
PureMouse asks which app is frontmost when a button some app binds is pressed, and which is under
the pointer when a scroll or a thumb-wheel movement starts, and only when some app has settings of
that kind. Each answer costs microseconds to a millisecond, and an idle mouse still costs nothing.

`ForegroundApp` does the lookups, AppKit-free and on demand (`Session.appButtons`, `appThumbWheel`,
`appProfiles`, `ScrollEngine.profileForBurst`); the Universal Control work reuses it.
`ForegroundApp.frontmost` uses SkyLight's `_SLPSGetFrontProcess` with `GetProcessPID`, falling back
to the frontmost window's owner: the Accessibility focused-application attribute took 8 to 40 ms or
failed outright, so it is not used. An app's `"default"` (`Config.Binding.nativeValue`) is in
`AppSettings.buttons` with no entry in `bindings`, so that press gets `nil` and performs the mouse's
own behaviour (`Config.nativeBehaviour(of:)`), freeing the pointer for that press if the control is
a gesture elsewhere (`Session.pointerFree`). Every control bound in any scope is diverted; pressed
where nothing binds it, the wheel press, back and forward post their ordinary click
(`NativeButton`), released in kind. A per-app `thumbWheel` keeps the global `reversed` and step it
leaves out. The thumb wheel's `inverted` (global) flips its scrolling only; actions follow `reversed`
of the scope settled at movement start (`Session.thumbSettings`), never `inverted` or natural
scrolling.

## Source layout

```
Sources/HIDPP/          protocol only: framing, IOKit transport, request/response handling,
                        typed feature wrappers
Sources/PureMouseKit/   shared by both apps: config model and decoder, status/control channel
Sources/puremouse/      the daemon: applying config, actions, gestures, smooth scrolling, one
                        session per mouse, discovery, reconnects, wake, reload, permissions
Sources/PureMouseAppSupport/
                        the menu side's logic, without AppKit or SwiftUI: the daemon link,
                        config editing and saving, select by pressing, where files live, status
                        words, update check, battery alerts, opening Settings
Sources/PureMouseMenu/  the menu bar app (AppKit status item and menu, no SwiftUI); the menu's
                        rows come from `MenuPlan`, which `StatusMenu` renders
Sources/PureMouseSettingsUI/
                        the Settings window and its SwiftUI panes
Sources/PureMouseSettings/
                        the Settings helper app around them
Sources/HIDPPTesting/   test support only: in-memory transport and stateful HID++ mouse from probe dumps
Tests/                  request handling and device behaviour against fakes, framing and event parsing,
                        config, gestures, scroll maths, config editing, the menu's rows
scripts/                build, install, uninstall, release, signing identity, icon
assets/                 app icon (Icon Composer source, compiled icon, README images), menu bar glyph
```

## Invariants

The rules below are easy to break and are not obvious from one file. Each names the symbol that
holds it; [Development](development.md#extending) says what a new feature or config section
touches.

### Layers

- `Sources/HIDPP` is protocol only (framing, transport, typed feature wrappers) and stays free of
  policy. Applying config, performing actions and scrolling live in `Sources/puremouse`.
- `Sources/PureMouseKit` is shared with the menu bar app and Settings: the config model and its
  decoder (`Config`, `Action` and its `named` table, `Keystroke` parsing, `AnyKey`, the
  range-checked decode helper), the `FileLock` both sides take, and the status and control channel
  (`Companion.swift`, [companion.md](companion.md)). It is data only: no HID, no event posting and
  no `Log` (the decoder collects problems such as `unknownButtons` and the daemon logs them).
  `ConfigCheck.validate` is the real decoder, so Settings never writes a file the daemon would
  reject. Shortcut specs are parsed and named by Kit's `Keystroke` only; the menu adds glyphs and
  spoken words.
- `Sources/PureMouseAppSupport` holds the logic the menu bar app and Settings share (`AppModel`,
  config editing and saving, `Locations`, `ShowRequest` over Kit's `SettingsRequest`,
  `SettingsLookup`, status words), tested in `Tests/PureMouseAppSupportTests`. It links no UI
  framework.
- No dependencies, and no AppKit or SwiftUI in the daemon or PureMouseKit. Only
  `PureMouseSettingsUI` and the Settings helper link SwiftUI; the menu bar app links AppKit only
  (`otool -L .build/release/PureMouseMenu` names no SwiftUI).
- The daemon and PureMouseKit use neither UserNotifications nor the network. Notifications live in
  the menu bar app, the on-demand update check in Settings and the daily one in the menu bar app
  ([ADR 21](adr/0021-scheduled-update-check.md)).

### Threads and idle cost

- All HID and HID++ work runs on the main actor. IOKit and CoreVideo callbacks hop to it
  (`MainActor.assumeIsolated` or `DispatchQueue.main`). The process serves the main queue with
  `runMainLoop()` (a `CFRunLoop` on the main thread), never `dispatchMain()`: that drains the main
  queue off the main thread, and on macOS 26 and earlier `assumeIsolated` then traps (it crashed on
  SIGTERM, before restoring the mouse).
- Idle cost is zero CPU. The optional daily update check is run by the system's
  background-activity scheduler, not a timer of ours. The display link runs only while a scroll is
  gliding. The bounded exceptions are the permission poll, the adoption retries and the reapply
  retries below; `IdleCostTests` fails on a new timer or poll in the daemon sources.
- The reapply retries are one `Session.configure`: 3 attempts, 200 ms apart
  (`SessionEnvironment.reapplyRetryDelay`), each request of an attempt waiting at most 600 ms
  (`reapplyAttemptTimeout`; per request, not per attempt). It starts on an event (wake,
  reconnect, link up, reload, adoption, Apply Settings Again) and ends after the third attempt, so
  a mouse that never answers costs nothing more until its next event. An attempt stops at a
  request the mouse needs to answer, but some lookups it can do without (battery source, event
  features) do not stop it, so one attempt against a mouse that answers nothing can wait on
  several requests: measured, a fully silent mouse is given up on after about 10 s with its
  feature indices known and about 15 s without them, not in two. That is only how long
  "Applying settings…" shows for a sleeping mouse; a mouse that starts answering at any moment
  is applied within about a second of it (below). There is no heartbeat, and nothing re-checks a
  mouse that is applied.

### Sessions

- Device settings are volatile: the mouse forgets them on every reconnect. Anything applied to it
  belongs in `Session.apply()`, which runs on adoption, reconnect, wake and reload. A newer
  `Session.configure()` supersedes one under way; only an offline mouse's other events
  (`Session.reconfigureIfOffline`) defer to a running one, and start one at most once per 30 s.
- **Applied state.** A session is `applying` from the start of `configure()`, `applied` (with the
  time, `Environment.date`) once `apply()` has run to its end for the current config, and
  `notApplied` after the third attempt fails **for a mouse that answered**: at least one reply
  (`HIDPPDevice.repliesReceived`) arrived during the configure and `apply()` still did not finish.
  A mouse that answered nothing at all, or whose receiver link is down, is asleep or away, not
  failed: its configure ends with `applied` nil and the mouse offline (`online` false), which the
  menu and General read as "Asleep", and its next link-up or event from the device (the
  `reconfigureIfOffline` guard, at most once per 30 s) starts a configure. A link-down report ends
  a configure under way and clears the state (`Session.linkWentDown`), so a late exhaustion cannot
  turn it into a failure. The state is published on those transitions only, so an idle mouse
  writes nothing. A `notApplied` mouse shows "Settings not applied" in the menu and General
  before "Asleep"; the menu's Apply Settings Again (`Control.reapply`, one token per request,
  aimed at every mouse, whatever `device` says) calls `Session.reapply()`, which starts a fresh
  configure at once, past the 30 s guard, and does nothing for a session that is not `notApplied`.
- **Request timeouts are leased.** The 600 ms (and `restore`'s 400 ms) is lent to the endpoint
  with `HIDPPDevice.lendTimeout` and ended by the lease's own number (`returnTimeout`): a retired
  configure, or one `restore` cancelled, returns its lease when it ends and so cannot reset the
  timeout its replacement or the restore is using.
- **Bound.** Requests are short (above), so one lost while the mouse was still waking fails in
  time for the next, and a mouse answering at any point in the window has its settings back
  within about a second of that moment: the request in flight (at most 600 ms), then either the
  rest of the apply or, if a request it needs was lost, 200 ms and another attempt. Wake (`Session.configureAfterWake`) starts every
  session's configure at once; the daemon's other wake work (notifications, permissions, Logi
  Options+, stragglers) follows 2 s later. A session whose receiver slot is known to be down
  (`linkDown`: the mouse is on another computer or switched off) is left alone by a wake. A mouse
  that is asleep when the Mac wakes and answers nothing in the window is offline with the
  applied state left out, as above, until its own reconnect or first event starts a configure.
- **Facts for About This Mouse.** After a successful configure the session reads the mouse's
  Easy-Switch hosts (HID++ 0x1814 `GetHostsInfo`, with names from 0x1815 where it reports them) and,
  once per mouse, its firmware (0x0003 function 1, per entity). They are reads only: the change-host
  command (0x1814 function 1) and every 0x1815 setter are never sent. A feature the mouse lacks
  leaves its field out; a failed read keeps the last value and does not fail the apply.
- Nothing may be persisted on the device or receiver: they must work normally without PureMouse. A
  persistent diversion (Logi Options+'s) is never written.
- Feature absence is cached per endpoint in `HIDPPDevice` (`knownPresence`; only a definite
  index-zero answer counts, [ADR 2](adr/0002-feature-absence-cache.md)), while "missing feature"
  log flags stay per session. Haptics is looked up only by a haptic action, never by apply, so
  `capabilities.haptics` stays unknown until one runs; an action's lookup that changes the
  capabilities publishes them (`Session.capabilitiesMayHaveChanged`). Haptic absence is logged
  once per session.
- Enhanced SmartShift may skip malformed or feature-error replies only; timeouts and transport
  failures must reach configure's retry handling. Feature summaries use indices already resolved by
  a successful apply, never extra adoption queries.
- On SIGTERM or SIGINT, `Session.restore()` returns the mouse to native behaviour, wheels first.
  Each of its requests times out after `Session.restoreTimeout` (400 ms), and quitting waits long
  enough for every one of them (`Daemon.shutdownDeadline`, 2 to 5 s), counting the restores of a
  pause still under way (`Daemon.restoreSteps`), so a missed reply cannot leave the rest diverted.
- `restore()` decides whether to hand the wheels back from `Session.wheelsMayBeDiverted`, not from
  the current config: after a reload that drops or disables `smoothScroll`, the replacement session
  inherits the flag and keeps it until its own apply has set the wheels native. One found diverted
  at apply is owed a hand-back until the mouse reads back native.
- A session that is `finished` (closed or restored) must not touch the device again. The daemon
  stops adopting once `shuttingDown` or `paused` (`Daemon.accepting`).
- Pausing from the menu (`Control.paused`) restores and drops every session. Nothing is adopted
  until those restores finish, even after a resume (`PauseGate`), and quitting waits for them
  (`Daemon.pausing`). A different product announced in a slot meanwhile only records the product:
  nothing replaces an endpoint a restore is using, and the slot's endpoint is replaced and
  identified afresh once the restores are done (`Daemon.replacementsDue`, `adoptStragglers`). A
  pause is never persisted.
- Held buttons (`HeldButtons`) are dropped, and native clicks released, whenever the mouse's own
  release may not come: link down, reconnect, reload, pause and quit (`Session.dropHeld`).
- A freshly adopted mouse (`Inherited.fresh`) is scanned once for temporary diversions a previous
  process left (`Session.scanStaleDiversions`) and releases those not bound. A timeout keeps the
  scan pending, across reloads too; a device error skips that control.

### One write at a time

- Device actions (`cycleDPI`, `toggleScrollMode`, haptics) and `apply()`'s DPI and SmartShift
  writes run on one chain (`Session.deviceActions`, a `SerialChain`), one at a time, each reading
  what is wanted (`liveDPI`, `scrollMode`) as it runs, so a press mid-apply is neither undone nor
  overwritten. `close()` and `restore()` cancel it (`Session.finish`), so an action waiting for
  transport ownership cannot send after them.
- Every change to which controls are diverted, and to the wheels' diversion, from `apply()`,
  capture or a Universal Control handoff, runs through one chain (`Session.enqueueDiversion`), one
  at a time and in the order asked, reading the wanted state (`Handoff`, including `away`) as it
  runs. Each write checks `finished` right before it goes out, not only when the body starts.
  `close()` cancels the chain, and a replacement session's chain starts after the old one's end
  (`Inherited.diversionAfter`), so no retired write lands after a replacement's. `restore()`
  cancels and drains the chain before releasing.
- Handing inputs back tries each wheel and control on its own (`Independently.each`); one that
  fails stays counted (`wheelsMayBeDiverted`, `divertedControls`) for the next apply or
  `restore()`.

### Capture and Universal Control

- Select by pressing (`Control.capture`) diverts every pressable, unbound control
  (`Session.beginCapture`) of every mouse, or only those whose key matches `capture.device`
  (`Daemon.targets`), for at most `Daemon.captureDuration`. The first press goes to `onCapture`
  and performs nothing; a gesture held as capture starts is dropped, so letting it go does not
  click. Every way out (press, timeout, cancel, reload, pause) goes through `Daemon.endCapture`,
  which hands the extra controls back, each independently (one that fails waits for the next
  apply). They count in `divertedControls` until released, so `restore()` and a replacement
  session release them too. Bound controls are not diverted for it, since they already reach the
  daemon. A capture still listening when the config reloads or the daemon pauses reports
  `cancelled`. A mouse adopted during a capture joins it (with `capture.device`, only if its key
  matches); one lost during it drops out. The daemon acts on a capture token once, so rewriting
  `control.json` with the same token does not restart it. A mouse with no key is reached only by a
  request without `device`.
- The primary clicks 0x0050 and 0x0051 (`Config.reservedControls`) are never bound or diverted:
  the decoder drops them with a warning, and `Session.isDivertable` excludes them from binding,
  capture and the stale-diversion scan ([ADR 8](adr/0008-primary-buttons-reserved.md)).
- While the pointer is on another Mac and `universalControl.handOff` is on, `Session.away`
  (`Session.setAway`) leaves the wheels and every diverted control native (DPI, SmartShift and the
  rest stay applied), so macOS forwards them. Status reports it as `away`, and the menu shows "On
  another Mac" in the device line. Apply, capture and
  new or replacement sessions all honour it (`Daemon.handingOff`, passed in
  `Session.Inherited.away`). Going away also stops any glide, drops held gesture state and ends a
  capture.

### Adoption and endpoints

- An endpoint that does not answer is retried after 1, 2, 4 and 8 s (`Daemon.adoptRetrying`,
  `Backoff.adoption`), one retry per endpoint whether attach, a connection notification, resume,
  wake or reload started it; pause, detach and shutdown cancel it. After that a receiver slot is
  left to its connection notification, so idle cost stays zero. A Bluetooth mouse has no
  notifications, so it is then tried once a minute until it answers, for about 16 hours
  (`Backoff.bluetooth`).
- Turning on a receiver's connection notifications is retried the same way
  (`Daemon.retryNotifications`), then again on wake and resume; pause, detach and shutdown cancel
  it.
- When a notification carries a different wireless product ID from the one known for the slot (a
  new device paired into it), the slot's session is closed as on a disconnect and the newcomer is
  adopted on a fresh `HIDPPDevice`, so no feature index, DPI list or state carries over
  (`Daemon.replaceEndpoint`). An ignored slot is identified again, and an identification of the old
  endpoint that finishes afterwards is discarded. The first announcement after attach only records
  the product.
- Identity is read at adoption (`Identification.read`): the name (0x0005), kind (0x0005
  getDeviceType), and model and unit IDs (0x0003), which give the key (`Config.deviceKey`). A mouse
  whose 0x0003 answers with an error, or that lacks it, is keyed by its product ID: the
  interface's for Bluetooth, the slot's wireless product ID on a receiver. A 0x0003 that times out
  leaves the key absent rather than guess, and that mouse uses the top-level settings and its
  identity `unresolved`: after each configure that succeeds it is read again, once
  (`Daemon.resolveIdentity`), and a mouse that now has a key is replaced by a session on that key's
  settings. A reload or reconnect configures again, so it is retried then, never in a loop or on a
  timer. An answer that arrives before the slot's first announcement is completed with the product it names (`Daemon.current`). An answer, an error included, is final, so a known identity is never read again. A model or
  unit ID of all zeros or all 0xFF counts as absent. The key is in the adoption log line
  (`model=`). Two mice of one model share a key, so they share `devices.<key>` and are both reached
  by a `device` request.
- A receiver mouse keyed by its product but adopted before its slot was announced gets its key, and
  a session on that key's settings, when it next links up (`Daemon.sessionSlotAnnounced`); while
  quitting or paused that only records the product. The daemon hands each session
  `config.forDevice(deviceKey)` at adoption and on reload; permission decisions cover every scope
  (`Config.everyScope`, `Daemon.postsEvents`).
- A setting the mouse cannot use is skipped quietly: a bound control it lacks is a debug line once
  per session; `toggleScrollMode` without SmartShift, and smooth scrolling without either 0x2121 or
  0x2130 (`Session.smoothScrollUnsupported`), an info line once per session.
- HID++ software IDs rotate per request, so a late reply cannot complete a newer request. A
  cancelled request fails at once instead of holding the endpoint until its timeout, and so does
  one still queued behind another (`HIDPPDevice.acquire` removes its entry). Only events reach
  `onEvent` (`Report.isEvent`): software ID 0, or a short HID++ 1.0 notification (sub-ID 0x40 to
  0x7F); a long report at those indices with another software ID is another program's reply. A
  connection notification is only a short report with sub-ID 0x41 heard on a receiver endpoint
  (`Receiver.isConnectionNotification`, used by `Session.handle` and `Daemon.watch`): a long event
  at feature index 0x41, on a receiver slot or a Bluetooth mouse, routes to its feature.
- A control is diverted only if one of its bindings can be performed (`Session.bound`,
  `Config.Binding.isPerformable`): device actions, `run` and `none` always can; an action that
  posts events (click, key, swipe, scroll, media) needs Accessibility; a gesture needs one
  direction that can act. Without the permission such a button stays native instead of being taken
  and doing nothing, and the log says so once. The permission is read once per process, so a grant
  restarts the daemon (`Daemon.pollPermissions`) and its new sessions divert as normal.

### Permissions

Permission checks are cached per process. The launchd-run daemon polls a child (`puremouse
permissions`) and restarts itself when a grant arrives (`Daemon.pollPermissions`), only for
permissions needed now (`Permissions.needed`: Accessibility when anything is bound or the wheels
may be taken over; Input Monitoring with a Bluetooth mouse or when opening HID devices failed). The
child runs after 2, 4, 8, 16 and 32 s and then once a minute, until `Daemon.permissionPollLength`
(10 minutes) after the latest start, wake, reload, control change or Bluetooth attach; each of those
starts or extends it. Without Input Monitoring a Bluetooth mouse is not retried after its first try.

Only needed permissions are asked for: at start, on a Bluetooth attach and after a HID open failure
the daemon requests `missingPermissions` (the needed ones not yet allowed), never both by reflex,
so a user with no Bluetooth mouse is not asked for Input Monitoring and Settings shows it as "Not
needed". A Bluetooth mouse that is seen but cannot be identified without Input Monitoring is listed
in `Status.waitingForInputMonitoring` (the name heuristic is `Daemon.mayBeMouse`, so a keyboard is
not listed), and the menu, the Mouse pane and General each offer Allow Input Monitoring for it. This
adds a status field and no timer or poll (`IdleCostTests`).

### Logi Options+

Whether Logi Options+ is running is looked up again, not once at start: `Daemon.recheckLogiOptions`
scans the process table at start, wake, reload, a control doorbell and each permission check, and
rewrites the status when the answer changed, so the notice appears or clears in place. A control
doorbell with no change (`AppModel.askDaemonToRecheck`) is what the Settings helper rings when its
window is shown (`SettingsWindowController.show`), and what the menu bar app or Settings rings when
Logi Options+ has quit after Quit Logi Options+ (a KVO watch on the app's `isTerminated`). No timer and no polling were added (`IdleCostTests`); process
launch notifications are not used, as they need AppKit in the daemon. The scan sees only this user's
processes (see [Troubleshooting](troubleshooting.md#logi-options)).

### Battery and DPI

- Events route only for features whose index is already resolved (`HIDPPDevice.feature(at:)`), so
  `Session.apply()` resolves the event-bearing ones (0x1B04, 0x1D4B, 0x1004 battery) first.
- Battery is read on each apply and then follows broadcast events, from one source
  (`DeviceState.batterySource`): 0x1004, else legacy 0x1000, else 0x1001's voltage, each only when
  those before it are absent. The source is resolved and selected before configuration writes, and
  that selection is inherited across reloads. Only the selected source's broadcasts are used.
  Battery is informational and never fails an apply. `charging` is true while charging or charging
  slowly, false once complete. 0x1004's level bits are masked by getCapabilities and the highest
  wins, as in Linux; a mouse that reports a percentage has its levels ignored, so `level` is
  derived from the percentage. 0x1000's percentage of 0 means unknown. 0x1001 gives a level only,
  banded from its millivolts (`BatteryVoltage.parseStatus`).
- DPI is snapped to the sensor's own list (0x2201 getSensorDpiList), read once per mouse and
  inherited across reloads. If the mouse answers the list request with an error, the configured
  value is sent unchanged; a timeout fails the apply so configure retries. A snapped DPI is logged
  once per mouse (`DeviceState.snapLogged`), not per reload.
- `cycleDPI` sets `Session.liveDPI`, which overrides `config.dpi` in `apply()`. `Daemon.reload`
  clears it only when that mouse's resolved `dpi` or `dpiPresets` changed (`Daemon.keepsLiveDPI`),
  and `Control.useConfiguredDPI` clears it on request, for every mouse or those whose key is
  `Control.device`. It picks the smallest preset above the current DPI, else the smallest, after
  snapping the presets to the sensor's list; with no `dpiPresets` it does nothing and logs an error.
- The DPI written is read back on every axis written (0x2202's Y too). When the sensor's list is
  known (`state.resolutions != nil`), a mouse that shows another value is refused
  (`Session.confirmDPI`, `DeviceState.dpiRefused`); without the list, a sensor's rounding is not
  taken as a refusal. A mouse whose X and Y lists share none is refused too. A refused mouse gets
  nothing more written, once logged, until a reload changes `dpi` or `dpiPresets`.

### Status

The daemon reports to the menu bar app only through `status.json` (`StatusChannel`): call
`statusChanged()` (`Daemon`) or `changed()` (`Session`) after anything in `Status` changes. Writes
are coalesced to one per main-queue turn. On shutdown, `running: false` is written last, after the
mice are restored (`exitReporting`). The fields are defined in [companion.md](companion.md#channel);
how the daemon fills them:

- A write is skipped when nothing in `Status` changed. `Device.id` is
  `<interface number>-<device index>`, the interface numbered in attach order. `dpiSteps` lists
  every value (157 on an MX Master 3S). `controls` lists only divertable controls and leaves out
  virtual ones (flag 0x80, e.g. 0x00d7), which cannot be pressed; `gestures` follows the control's
  raw-XY flag. While paused, `devices` is empty: the sessions are dropped.
- `Device.applied` is the applied state above (`applying`, `applied` with the time, `notApplied`),
  `firmware` the main firmware as "RBM 22.01 B0015" and `hosts` the current Easy-Switch host and
  each host's name or "not paired", all absent where unknown. A change of any of them is a status
  change and a write; their absence from an idle daemon's status is what keeps it quiet.
- Capabilities come only from lookups apply has already made (`HIDPPDevice.knownPresence`,
  `Session.capabilities`), so building them sends nothing, and are absent until the first apply.
  Haptics (0x19B0) is looked up only by a haptic action, so it is unknown until one runs; a
  capability learned that way is published then. A member is true when one of its features is
  present, false only when all are known absent, and left out when unknown: `dpi` (0x2201, 0x2202;
  false once refused), `smartShift` (0x2110, 0x2111), `smoothScroll` (a main wheel PureMouse can
  take over, 0x2121 or 0x2130; false when the notched wheel refused), `battery` (0x1004, 0x1000,
  0x1001). They are kept across reloads.
- The config file is watched as well as its directory, since editors that write in place leave the
  directory unchanged. A symlinked directory (a dotfiles setup) is watched at the folder it points
  to, and so is the parent of the directory as written and of every link in the chain its name
  leads through (up to 8, each folder once), so a link or its target swapped or replaced at any
  hop is followed. Every event
  re-resolves the path and re-arms the watches (`ConfigWatcher.arm`); a change to a parent alone
  reloads only if the directory the path leads to changed. While the directory is absent
  (deleted, renamed away, a dangling link or never created) the nearest existing ancestor of where
  it leads is watched instead. The config in effect stays until the directory returns, and then it
  reloads once; an absent directory is logged but does not set `config.error`. Two changes go
  unnoticed until SIGHUP reloads: renaming a real directory above those watched parents, and
  swapping a link in the middle of a hop's target (`hop/current/config` where `current` is itself
  a link), since only each hop's last component is followed. Only file-system
  sources are used, so idle costs nothing, and a watcher's descriptors close when it stops or is
  released.
- A reload that fails leaves the previous config in effect and reports `config.error`
  (`ConfigCheck.message`, which names the field); the next successful load clears it.

## Protocol references

Logitech does not publish HID++ 2.0, so the feature layouts here were checked against the open
implementations in [Solaar](https://github.com/pwr-Solaar/Solaar) (`hidpp20.py`) and
[logiops](https://github.com/PixlOne/logiops); [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
is a further reference. `puremouse probe` dumps a mouse's raw feature state for comparison.

SmartShift Enhanced and haptic layouts follow Solaar's
[`SmartShiftEnhanced`, `ScrollRatchetTorque` and `PlayHapticWaveForm`](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/settings_templates.py).
Legacy battery status follows
[`decipher_battery_status`](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/hidpp20.py)
and its function-0 broadcast handler. SmartShift parse tests use response parameters from
[OpenLogi's MX Master 4 and Anywhere 3S fixtures](https://github.com/AprilNEA/OpenLogi/tree/master/fixtures/devices),
available under its [MIT licence](https://github.com/AprilNEA/OpenLogi/blob/master/LICENSE-MIT).
These layouts have not been tested on those mice by this project.

The 0x2130 (low-resolution wheel) and 0x2202 (extended adjustable DPI) layouts are inferred from
Solaar's settings templates (`LowresMode`, `ExtendedAdjustableDpi`, `produce_dpi_list`), not checked
against a capture: no raw reply of either from a real mouse is public, and the Linux driver has no
code for them. The 0x1001 (battery voltage) layout follows Solaar's `decipher_battery_voltage` and
the driver's `hidpp20_battery_map_status_voltage`, which agree, and one raw sample (a G915). The
direction of a positive 0x2130 notch count rests on Solaar alone and awaits an owner with an M750
or MX Ergo. Because a write cannot be assumed to take, PureMouse reads the 0x2130 reporting byte
back after diverting it and leaves a wheel that does not confirm scrolling natively, and reads the
DPI back from every axis it wrote. The MX Master 3S, MX Master 4 and MX Ergo fixtures are raw
captures from OpenLogi; the G305 and Superstrike fixtures are hand-built from Solaar's device
listings, and say so in their headers. Layouts were read for protocol facts, and no code was
copied.

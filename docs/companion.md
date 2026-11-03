# Menu bar app and daemon: the contract

PureMouse is two resident processes in one app bundle, plus Settings on demand:

- **The daemon** (`PureMouse.app/Contents/MacOS/puremouse`): headless and unchanged in identity
  (bundle ID `io.github.mblauberg.puremouse`, executable path, signature), so existing
  Accessibility and Input Monitoring grants keep matching. It alone talks to the mouse.
- **The menu bar app** (`PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app`, bundle ID
  `io.github.mblauberg.puremouse.menu`, `LSUIElement`): the status item and its menu, and the
  low-battery notifications and update checks. It needs no privacy permissions and never opens HID
  devices. With Show in menu bar off it still runs, without a status item (windowless).
- **The Settings helper** (`PureMouse.app/Contents/Helpers/PureMouse Settings.app`, bundle ID
  `io.github.mblauberg.puremouse.settings`, a regular app with a Dock icon): the Settings window.
  The menu bar app opens it, and it quits when its window closes
  ([ADR 9](adr/0009-settings-helper-app.md)). It edits the config and sends control requests as
  the menu bar app does, under the same locks.

Either works without the other. With the menu bar app quit, or its icon hidden, the mouse behaves
exactly as configured; with the daemon stopped, the menu shows "PureMouse Is Off" and can start it.

The menu bar app and the Settings helper never open HID devices: they edit the config file and talk
to the daemon only through this channel and the daemon CLI. Neither polls: they wake on
notifications, file events and the daemon's process exit. The resident menu process never holds a
window or SwiftUI, and never restarts itself; its menu is rebuilt on open. The helper quits when its
window closes, saving its edits and cancelling a select by pressing as it goes
(`applicationWillTerminate`, also on SIGTERM). Every quit from outside (SIGTERM, the quit event, a
capture) ends any open sheet first, since AppKit ignores `terminate` while one is attached, and
finishes the quit itself (`willTerminate`, then exit) when SwiftUI attaches a sheet again whose state
still shows it (`terminateClosingSheets`).

## Channel

All files live in `~/Library/Application Support/PureMouse/` (`Companion.directory`), are written
atomically (`Companion.write`, mode 0600) and are followed by a Darwin notification
(`notify_post`) as a doorbell. Neither side polls or runs timers while idle.

| File | Writer | Reader | Doorbell |
|---|---|---|---|
| `status.json` (`Status`) | daemon | menu | `io.github.mblauberg.puremouse.status` |
| `control.json` (`Control`) | menu | daemon | `io.github.mblauberg.puremouse.control` |
| `~/.config/puremouse/config.json` | menu or the user | daemon | none: the daemon watches the file |

The Swift types in `Sources/PureMouseKit/Companion.swift` are the schema.

The table gives the doorbell names as shipped. When `PUREMOUSE_COMPANION_DIR` is set (tests,
development, the footprint rig), both sides append `.` and an 8-digit hex FNV-1a hash of that
directory's resolved path (symlinks followed, no trailing slash, so `/tmp/fx`, `/tmp/fx/` and
`/private/tmp/fx` agree) to all three doorbell names (`Companion.doorbell`), so a copy running on a
fixture directory neither rings nor answers an installed app. An empty value counts as unset. Unset leaves the names above.

### Status (daemon → menu)

The daemon rewrites `status.json` when anything in it changes:

- start;
- each device adopted, lost, woken or asleep;
- battery change;
- DPI or wheel-mode change;
- a mouse's settings starting to apply, being applied or failing to apply (`devices[].applied`),
  and a firmware or Easy-Switch fact first read or changed after a configure;
- Logi Options+ starting or stopping, seen at the next re-check (`logiOptionsRunning`);
- permission grant (the restart then writes a fresh one);
- a Bluetooth mouse seen without Input Monitoring (it joins `waitingForInputMonitoring`);
- config load or failure;
- pause or resume;
- the pointer moving to another Mac or back, when that hands the mice back (`away`);
- capture progress;
- shutdown, which sets `running: false` as its last act after restoring the mice.

Writes are coalesced on the main queue, at most one per run-loop turn.

The menu treats the daemon as running when `running` is true and `kill(pid, 0)` succeeds. A
missing or stale file means "PureMouse Is Off".

### Control (menu → daemon)

- `paused: true`: every session is restored to native behaviour (`Session.restore()`, wheels first),
  sessions are dropped and adoption stops. `paused: false` re-adopts connected mice and applies the
  config. Pausing is not persisted: the daemon deletes `control.json` at start, under
  `control.json.lock`, so a menu write already under way lands first and is deleted with it. The
  daemon waits at most 5 s for that lock; if another process still holds it, startup logs one line,
  skips the delete (it never deletes without the lock) and carries on. The menu's own lock waits
  stay unbounded.
- `capture: {token}` with a new token starts **select by pressing**. For up to 10 s every divertable
  control of every mouse is diverted; the first press reports `{token, state: pressed, cid,
  deviceID}` and performs no action; then the normal diversion is restored. Timeout reports
  `timedOut`. Setting `capture` to nil reports `cancelled` and restores at once.
- `useConfiguredDPI: token`, when new, drops the DPI chosen by `cycleDPI` and sets every mouse to
  the config's `dpi`. The menu sends it after saving a DPI choice while a mouse reports another
  value: choosing the value already saved leaves the file unchanged, and a reload that leaves
  `dpi` alone keeps the cycled one. Every control write repeats the last token, so a later pause
  or capture cannot erase it unread; the daemon acts once per token.
- `reapply: token`, when new, is Apply Settings Again: it starts a fresh `Session.configure()` on
  every mouse whose settings are not applied, past the 30 s offline guard (`Session.reapply()`).
  It is independent of `device`, which aims `useConfiguredDPI` only, so neither request narrows
  or widens the other when both are pending. It does nothing for a mouse that is applied or applying.
  The menu sends it from the attention row that shows while a mouse is not applied, and repeats
  the last token on every control write, as for `useConfiguredDPI`, so the daemon acts once per
  token.
- A bare doorbell, with `control.json` unchanged, asks the daemon to look again at what it learns
  only by looking: whether Logi Options+ is running and which permissions are missing. The Settings
  helper rings it when its window is shown, and the apps ring it after asking Logi Options+ to quit.
  The daemon acts on the file as it stands, so nothing repeats.

### Config (menu → daemon)

The menu edits `config.json` as a JSON tree (`ConfigTree`): it changes only the keys a control owns
and keeps every other key, unknown ones included. It records edits as the keys they set, and
`ConfigFile.save` replays them onto the file as it is when saving, so a hand edit made meanwhile
survives. A new object is recorded key by key, so it merges with one added by hand; an emptied one is
removed whole; removing a key that is not there is a no-op, so it never prunes an ancestor. With no
pending edit nothing is written. It refuses to build on a file that does not parse or validate, and
writes through `JSON.encode` (shortest decimals, sorted keys, whole and big numbers kept digit for
digit), never `JSONSerialization`. Before writing, it validates the whole file with
`ConfigCheck.validate`, which runs the daemon's own decoder. Only Reset All Settings and Restore Last
Working replace the whole file (`ConfigFile.replace`, keeping `config.json.bak`); Open Config File
only creates a missing file (`createIfMissing`).

Every config write (a save, Reset All Settings or Restore Last Working with its `config.json.bak`,
creating a missing file) is one read-merge-replace under an exclusive `flock` on `config.json.lock`
beside the resolved config (`ConfigFile`, `FileLock`), so two writer processes never drop each
other's keys; a writer waits while another holds it. The lock is a separate file because the
config is replaced atomically. Hand edits take no lock: saves replay their keys onto the file as
it is. `control.json` writes likewise lock `control.json.lock` in the companion directory, read
the file and change only what that request means (`DaemonLink.writeControl`): a pause sets
`paused`, a DPI request sets `useConfiguredDPI`, a capture sets `capture` and its end clears it only
while the file still holds that capture's token. Every other field stays as the file has it; with
no file, `paused` starts from the status.

The daemon watches the config's directory with a `DispatchSource` (the file is replaced atomically,
so the file's own descriptor goes stale). It reloads when the file's bytes change, debounced
about 150 ms, exactly as for SIGHUP. Hand edits therefore apply on save. A failed load keeps the
previous config and reports `config.error`.

Slider writes from the menu are debounced to about 300 ms.

## Versioning

The menu and the daemon ship together in one bundle, so the status and control formats change with
the bundle and nothing is kept for older versions. `schema` is bumped when they change (3 with the
applied state, firmware and Easy-Switch hosts, and the `reapply` request); a menu that
sees a higher `schema` shows "update PureMouse" (`AppModel.statusTooNew`), also when it cannot decode
a newer status. A capability member that
is missing means unknown: a reader shows the option, and hiding needs an explicit `false`.

### Device identity and capabilities (Status)

All optional; nil members are left out of the JSON.

| Field | Type | Meaning |
|---|---|---|
| `devices[].model` | String | The device key used by `devices.<key>` in the config: `m` plus the 12 lowercase hex digits of the 0x0003 model ID when the mouse reports one, else `p` plus the 4-digit lowercase hex product ID (e.g. `pb02c`). Absent when neither is known. Two mice of one model share it |
| `devices[].unit` | String | The 0x0003 unit ID as 8 lowercase hex digits, when known. Stable for one physical mouse, for per-unit state such as low-battery alerts. Never written to the config |
| `devices[].kind` | String | A word such as `mouse`, `trackball` or `keyboard`. |
| `devices[].capabilities` | object | What the mouse reports. Members: `dpi`, `smartShift`, `smoothScroll`, `thumbWheel`, `haptics` and `battery` (each Bool: true has it, false reported not to; absent unknown, e.g. a lookup that failed transiently). Absent until the mouse's first apply has finished |
| `devices[].controls[].gestures` | Bool | The control can report raw XY movement. Absent when unknown |
| `devices[].applied` | object | Whether the mouse's settings are on it: `{state, at}`. `state` is `applying` (a configure is under way and the mouse has answered it; a mouse that has not answered keeps its previous state), `applied` (`Session.apply()` ran to its end for the current config; `at` is the wall-clock time, ISO 8601) or `notApplied` (the mouse answered but the configure's three attempts failed; a mouse that answered nothing, or whose link is down, is offline and the field is absent). Absent before the first configure, and for a mouse that is asleep or away. Written on those transitions only |
| `devices[].firmware` | String | The main firmware as the mouse names it, such as `RBM 22.01 B0015` (name, major.minor, build). Read once per mouse after its first successful configure, with 0x0003 function 1. Absent when the mouse does not report it |
| `devices[].hosts` | object | The Easy-Switch hosts the mouse reports (HID++ 0x1814, with names from 0x1815): `{current, slots[]}`, `current` the zero-based index of this Mac's host, each slot `{name, paired}` with `name` the computer's name where the mouse gives one. Re-read after each successful configure. Absent for a mouse with one host or without the feature. Read only: PureMouse never sends the change-host command |
| `capture.model` | String | The device key (`devices[].model`) of the mouse whose control was pressed |
| `waitingForInputMonitoring[]` | array | Bluetooth mice the daemon has seen but cannot adopt because Input Monitoring is not allowed, each `{id, name}` (`WaitingDevice`). Absent or empty when none. Added without a `schema` bump: a reader treats absent as empty (`Status.waiting`), and an older menu ignores it |

### Requests aimed at one mouse (Control)

| Field | Type | Meaning |
|---|---|---|
| `capture.device` | String | Listen on the mouse with this device key (`devices[].model`) only. Absent means every mouse |
| `device` | String | Qualifies `useConfiguredDPI`: set only the mouse with this device key to the config's `dpi`. Absent means every mouse |
| `reapply` | Int | A token: a new value is Apply Settings Again for every mouse that is not applied; `device` does not aim it |

Settings sets `capture.device` and `device` to the mouse chosen on Mouse (none for All Mice). The
status menu sets neither and writes the top-level `dpi`. A press reports the mouse's key in
`capture.model`, and Settings switches Mouse to that mouse's scope when it is one the pop-up lists.


## New config keys

| Key | Type | Meaning |
|---|---|---|
| `smoothScroll.enabled` | Bool, default true | false keeps the tuning but scrolls natively (wheels not diverted) |
| `dpiPresets` | [Int], 0–8 entries, each within `Config.dpiRange` | shown in the menu; cycled by `cycleDPI` |
| action `cycleDPI` | action name | next preset after the current DPI, wrapping. Live only: kept across reconnects, cleared when a reload changes `dpi` or `dpiPresets` |

## Login and lifecycle

The daemon CLI owns every launchd change (`LoginItem.swift` holds the policy; a `LoginService`,
`LaunchdAgentService`, holds the mechanism, so the policy is tested against a fake). The menu app
and the Settings helper run these commands through the daemon binary in the app they are nested
in, `PureMouse.app/Contents/MacOS/puremouse` (`Locations`).

`LoginService.stop` waits for a running instance to finish restoring the mouse before it
returns: `LaunchdAgentService` boots the job out and polls until launchd no longer has it loaded
(up to 50 looks, 0.1 s apart), and throws if it is still there, so a replacement never starts
while the old daemon is still handing the wheels and controls back. Keep that wait in `stop`.

"Hidden" is remembered by a `menu-hidden` file in `Companion.directory`, written by `menu off`
and removed by `menu on`; `unregister` keeps it. Hidden does not stop the menu agent: it stays
registered and running, reads the marker as it starts (`Locations.showsInMenuBar`) and shows no
status item, so low-battery notifications and the update check go on
([Footprint](#footprint) has the cost). `menu on` and `menu off` therefore restart the menu agent so it
reads the marker. The CLI calls `setsid()` and boots the menu agent out last, after removing its
plist, because launchd kills the menu job's process group (which includes the CLI it spawned).
When the menu bar app itself runs `register`, `menu on` or `menu off` and its agent is already
loaded, the agent is left running (the plist is still rewritten); restarting it would quit the
caller. On `menu off` the app then removes its own status item and carries on
(`AppController.hideMenuBarIcon`). `menu on` only comes from Settings (the windowless process has
no menu), which can restart the agent.

"Starts at login" and "is running now" are separate, and each command changes only the axis the
table gives:

| Command | Starts at login | Running now |
|---|---|---|
| `puremouse login on` | on | unchanged |
| `puremouse login off` | off | unchanged (a running job stays loaded until logout or `stop`) |
| `puremouse start` | unchanged | on (daemon and menu) |
| `puremouse stop` | unchanged | off |
| `puremouse register` / `unregister` | on / off | restarted / off |

| Command | Effect |
|---|---|
| `puremouse register` | writes and boots both agents (daemon `KeepAlive`; menu `RunAtLoad`, `KeepAlive: {SuccessfulExit: false}`, `MallocSpaceEfficient`), the menu hidden or not. Prints the outcome |
| `puremouse unregister` | boots out both agents and removes both plists |
| `puremouse login on` / `off` | writes both plists without booting anything, or removes both without booting anything out. A running agent is left as it is |
| `puremouse start` | starts the agents that have no process and leaves running ones alone: a job that is not loaded is bootstrapped, one that is loaded without a process (the menu after Quit) is kickstarted, or booted out and bootstrapped again when the executable `launchctl print` shows for it is not this copy's. A registered job's plist is first rewritten for this copy of the app, so a moved app does not start from the old path; it stays registered. An agent that is not registered runs from a plist in `launchd/` under `Companion.directory`, which launchd does not load at the next login and which stays there until `stop` removes it |
| `puremouse stop` | boots out both agents but keeps their plists: **Quit PureMouse**. Both start again at login if registered |
| `puremouse menu on` / `off` | removes or writes the `menu-hidden` marker and restarts the menu agent only, so it comes back with or without its status item: **Show in menu bar** / **Hide Menu Bar Icon** |
| `puremouse login-status` | prints one JSON object and changes nothing: `{"daemon":"enabled","hidden":false,"menu":"notRegistered","service":"launchd"}` |

Every command that changes what is registered or running (`register`, `unregister`, `stop`, `start`,
`login on|off`, `menu on|off`) holds an exclusive lock on `lifecycle.lock` in `Companion.directory`,
so a `stop` and a `start` that overlap (the menu and a terminal, or a double click) run one after
the other. A command that cannot take it within 30 s fails with a message naming the lock.
`login-status` takes none.

`login-status` fields: `service` names the mechanism (`launchd`); `daemon` and `menu` are the job's
state: `notRegistered` (does not start at login), `enabled` (does), `requiresApproval` (registered,
but the user must approve it in System Settings › Login Items; no mechanism reports it yet) or
`notFound` (the build has no such job, e.g. no menu bar app); `hidden` is whether `menu off` is in
force. The decoder is `LoginStatus` in `PureMouseKit`. It says nothing about what is running: a
job started with `start` while unregistered reads `notRegistered`. Settings reads its "starts at
login" answer from it rather than looking for a plist file.

Settings opens the same way from everywhere (`SettingsLauncher`): `show-settings` in
`Companion.directory` is written with the pane to show (empty: the last one; `general`, `mouse`,
`apps` or `about` for a tab, `buttons`, `scrolling` or `pointer` for Mouse on that segment; a dot and a
sheet name opens a sheet over the pane, `pointer.presets` for Pointer's presets list, which the menu's
Edit Presets… row asks for; `apps:` and a bundle identifier opens Apps on that app's page, which the menu's
"Settings for <app>…" row asks for, listing the app first if the config has none and writing nothing
until a setting is chosen), the doorbell
`io.github.mblauberg.puremouse.menu.show` is posted, and the helper is opened with `NSWorkspace`,
which starts it or brings the running one forward (one instance per bundle ID). A running helper
reads the file on the doorbell; a starting one reads it at launch. Only a stamp from the last 5 s
counts, and the reader removes it (`ShowRequest`). Every writer (the menu app, and the daemon's
`openSettings`) and every reader goes through Kit's `SettingsRequest`, which holds `show-settings.lock`
and replaces the file atomically, so a reader never sees a half-written pane or removes a request
written after it read. The menu app no longer listens on the doorbell. A helper that LaunchServices
still lists but whose process has exited is opened again 0.3 s later, unless a newer open has
superseded it. Quit PureMouse first leaves a `settings-quit` stamp beside `show-settings`, then
waits up to 3 s for an open under way and quits the helper it starts. A helper that starts later
still, within 60 s of the stamp and with no request written since, exits at launch; any new
request clears the stamp.

Opening PureMouse.app from the Finder runs `register`, then `openSettings`: it writes `show-settings`
and opens the Settings helper (`Contents/Helpers/PureMouse Settings.app`) itself, which reads the
stamp at launch. The menu app is not opened: `register` already starts its agent, and with the icon
hidden Settings still opens and the icon stays hidden. `open` is tried
twice, a second apart. `open` exiting 0 does not prove Settings opened (LaunchServices can answer with
a helper that is quitting), so `openSettings` also rings the doorbell, so a running helper reads
the request, and waits up to 2 s for the helper to remove the file (`ShowRequest` does when it reads
it). If it is still there, the request is written again and `open` is tried once more, unless Quit
PureMouse left a `settings-quit` stamp meanwhile: a new request would clear it and bring Settings back,
so nothing more is done. If the build has no helper, or it will not open, the old alert is shown
instead; registration has already happened by then. An update (ADR 22) starts the new copy as
`register --relaunch [--settings=<pane>]` instead: `register`, then `openSettings` on that pane (empty:
the last one) only when `--settings` is given (best effort: the old menu app waits up to 3 s for the
old helper to exit first, so a helper seen to exit in that time cannot read the request and then quit; one that is still there after it can, and Quit or Hide during the wait starts nothing), and the Finder launch's
failure alert if registering fails (the old menu app is gone by then and `open` only says it launched). The menu app itself opens Settings when it was
opened by hand rather than by launchd (a copy that is neither launchd's nor showing an icon quits
once Settings is open), when it finds a fresh stamp at launch, and when it is reopened
(`applicationShouldHandleReopen`). It keeps a single instance: a second launch opens Settings and
exits, and the running one keeps the icon (a copy on an overridden channel, `PUREMOUSE_COMPANION_DIR`, is its own
instance, so a dev run sits beside an installed one). If the user has blocked the item under System Settings ›
Menu Bar, opening the app still reaches Settings.

General's Startup section keeps the two axes apart, each control running one command
(`LoginAction`, `PureMouseAppSupport`):

| Control | Reads | Runs |
|---|---|---|
| **Open at login** switch | `login-status` (`OpenAtLogin`: on when the daemon is `enabled` or `requiresApproval`) | `login on` / `login off`, with no confirmation; it never stops anything |
| **PureMouse is running** Start / Stop | the status file's liveness (`AppModel.daemonRunning`) | `start` / `stop`; neither changes the login setting |
| **Show in menu bar** | the `menu-hidden` marker | `menu on` / `menu off` |

The switch reads `login-status` again after each command, so it shows what is so even if the
command failed. When `login-status` reports `requiresApproval`, an extra row says to allow
PureMouse under System Settings › General › Login Items, with a button that opens that pane.
`unregister` stays a CLI-only full removal.

The helper runs `menu on` and `menu off` itself. It is not in the menu agent's process group, so
hiding the icon from Settings leaves Settings open. Turning on Open at login there runs `login on`,
which restarts nothing. Quit PureMouse quits the helper first, which saves its edits and cancels a select by pressing
still listening, then runs `stop`. Quit in the helper's own menu (⌘Q) quits only Settings.

## Low-battery notifications

The low-battery notification (`BatteryAlert`, `Notifier`) lives in the menu bar app. It is decided
on each status the daemon writes, and on each config change, from the band already announced per
mouse, kept in `battery-alerts.json` in the companion directory so a restart cannot repeat it.

- A mouse is keyed by its device key plus its 0x0003 unit ID when the status has both
  (`Status.Device.unit`), else by its status device id. With a stable key and a recorded band, a
  reconnect (or the menu app starting) is judged against that band, so a mouse that drained while
  away still warns once; otherwise the first reading after it connects only records, since a
  reconnect cannot be told from a different mouse.
- `BatteryAlertStore.process` is the pure decision: it returns the alerts to post and the
  notification ids (`battery.<key>.<band>`) to take down (`Notifier.removeDelivered`) when the mouse
  recharges (charging, or 25% and up), when a deeper band replaces a shallower one, and once when
  the switch is turned off. A post still waiting for permission is cancelled by a withdrawal of its
  id (`NotificationDelivery`).
- The file is versioned; one in any other format is discarded and alerts start fresh.
- Hiding the icon changes nothing here: the launchd-run menu process (`AppController.resident`)
  goes on without a status item and posts, consumes bands and asks for permission as before. Only
  a copy opened by hand without an icon, which ends when Settings closes, gets no notification
  callbacks, so it neither posts nor consumes a band.
- Permission is requested lazily: at the first notification, or when the menu app sees the switch
  turned on in the config. macOS asks per app, so the helper cannot ask. The menu app records a
  denial in its own defaults domain as it learns it (`NotificationPermission`, read at launch and as
  Settings opens), and the helper reads it there for the General pane's hint, watching it
  (key-value observing) while that pane shows.
- `UNUserNotificationCenter` needs a bundle, so a bare dev run posts nothing.

## Footprint

The daemon's budget is unchanged: zero CPU while idle, about 10 MB. The menu app must use zero CPU
while idle, with no timers or polling. Its footprint is `phys_footprint` from `footprint(1)`, and
the figures below are medians of 5 runs of `scripts/measure-menu.sh` (`docs/development.md`,
"Footprint rig") on a spare Mac, macOS 27.0.1, arm64, on 2026-11-02. They move with the OS, so
read them as "about" and repeat the rig after each macOS release. The bare AppKit column is
`scripts/measure-bare-appkit.sh` (5 runs, the same Mac and day).

| Menu app, release build | Without the variable, MB | Shipped (`MallocSpaceEfficient=1`), MB | Bare AppKit status item and menu, same Mac |
|---|---|---|---|
| fresh, about 4.5 s after launch | 11.9 | 8.6 | 10.8 |
| after 1 menu open | 18.4 | 12.9 | 15.2 |
| after 3 menu opens | 18.6 | 13.0 | 15.4 |
| after 10 menu opens | 18.8 | 12.9 | 15.6 |
| after 200 status doorbells, 10 ms apart, menu never opened | 12.1 | 8.8 | |
| while the Settings helper is open | 12.0 | 8.6 | |
| 1.5 s after the Settings helper quits | 12.1 | 8.6 | |
| after 5 opens and quits of the Settings helper | 12.1 | 8.5 | |

| Settings helper, release build | Without the variable | Shipped |
|---|---|---|
| its own footprint, 2 s after its window is on screen | 44.0 MB | 34.4 MB |
| cold start, from the menu being asked for Settings to the window on screen | 518 ms | 526 ms |

The shipped column is the rig, which passes on the Info.plist's `LSEnvironment` (the agent's plist
sets the same variable); the other column is the same build without it (same Mac, same day). The
helper's Info.plist sets the variable too, so it has it however it is opened (LaunchServices also
passes the menu app's environment on to the app it opens). The cold start's slowest run was each
time the first (1154 and 972 ms).

Re-measured on 2026-11-03 at main 990927a (the same Mac, shipped column only), every scenario is
up about 0.7 to 1.1 MB and still inside its budget: fresh 9.4, after 1 menu open 14.0, after 10
opens 14.1, after 200 doorbells 9.4, with the helper open or after it quits 9.3 to 9.4, and the
helper itself 35.7 MB, with a cold start of 654 ms. Several menu and Settings changes landed
between the two runs (the Settings request lock, the login controls, the battery notifications);
the growth was not bisected. The comparisons below are from the 2026-11-02 set.

With Show in menu bar off the menu app stays resident without a status item (`AppController.resident`), so
battery notifications and the update check carry on. Medians of 5 rig runs on the same Mac on
2026-11-03 (shipped build), two sets of 5 on the first-run branch: fresh 6.0 to 7.1 MB (the
shown icon: 9.1 to 10.8), after 200 doorbells with the last a low battery 5.9 to 7.0, 1.5 s after
the Settings helper quits 6.0 to 6.9, and after an update check 6.8 to 7.8. The spread between the
two sets is the Mac's (the shown icon's fresh figure moved the same way between sets), not the
change's: on the same day the shown icon's open-1 was 13.3 on main and 13.5 on the branch in the
quiet set. With no AppKit menu to build, the windowless process costs about 3 MB less than the shown one.

What the numbers say:

- **The first menu open costs about 4 MB, once** (8.6 to 12.9 MB shipped; 11.9 to 18.4 without
  the variable). Later opens add nothing (12.9 MB after ten). A bare `NSStatusItem` with an
  `NSMenu` and nothing else grows by about 4 MB on its first open (10.8 to 15.2 MB), so the cost
  is AppKit's.
- **Fresh is about 1.5 MB lower than with Settings in the menu's own process** (8.6 against 10.1 MB
  shipped; 11.9 against 13.8 without the variable). The menu no longer links SwiftUI, which is the
  likely difference.
- **Status updates barely moved it.** 200 doorbells posted 10 ms apart, `status.json` changed
  before each, left it 0.2 MB above fresh (8.8 against 8.6 MB shipped; 12.1 against 11.9 without
  the variable).
- **No growth was seen across the measured opens and doorbells.** The earlier question was a
  repeating 272 KB block per open. It was not reproduced: after 30 opens under
  `MallocStackLogging`, `heap -addresses=all` listed no live block of that size (the largest live
  block was 64 KB), so no owner could be named. One run on 2026-11-02, with
  `scripts/measure-menu.sh --blocks`.
- **Settings costs the menu nothing.** With the helper open the menu stays at its fresh figure
  (8.6 MB shipped), and it is there again after the helper quits, once or five times. The helper's
  34 MB is its own and goes when it quits. Before the helper, Settings in the menu's own process
  added about 24 MB on opening (to 33.9 MB shipped; about 29 MB, to 43.1, without the variable)
  and gave back only about 9 MB on closing (to 24.9 MB; about 4 MB, to 38.9, without), even after
  `malloc_zone_pressure_relief`: AppKit and SwiftUI keep the pages. Hence the helper
  ([ADR 9](adr/0009-settings-helper-app.md)).
- **Allocator.** The growth was freed small-malloc pages that stay resident and that
  `malloc_zone_pressure_relief` does not return. The menu app runs with
  `MallocSpaceEfficient=1` (a preference for reusing freed space over speed), in its launchd
  environment and, for a launch by the Finder, `LSEnvironment` in its Info.plist. The gate ran on the
  branch build against main's, five runs each, side by side, with Settings still in the menu's
  process: 14.1 against 19.9 MB after 3 opens (0.71 times) and 10.1 against 13.8 fresh. The
  variable is undocumented, so a macOS release may ignore it; the rig is repeated after each one.
- **The prefs-domain caveat.** For a while the rig's numbers were bimodal: some launches started
  about 4 MB higher, even for the fresh and doorbell scenarios, and a fresh bundle id or
  `defaults delete` of the rig's domain brought them back. The cause is a transient state of the
  preferences domain that we could not reproduce on demand, so the rig clears its domain before
  every launch. An installed app that carries that state may read several MB above these figures.

The menu app links no SwiftUI and never shows a window, so it never has to start over. The menu
itself is a plain `NSMenu` built on open (`menuNeedsUpdate`). `scripts/measure-menu.budgets`
holds the limits the rig checks; measure with the rig, or `footprint`/`vmmap --summary`, before and
after each change, and the menu app again after Settings has opened and closed.

### With automatic update checks on

The menu app now owns the daily update check (ADR 0021, `docs/privacy.md`): `NSBackgroundActivityScheduler`
holds the wait, so there is still no timer of ours and an idle app wakes for nothing. The rig can
turn the checks on and run one at launch (`--env PUREMOUSE_RIG_UPDATES=check`, a DEVHOOKS-only
hook that writes what the check found to `update-check`; the rig's version is not a release number,
so any release counts as newer and a notification is attempted). Medians of 5 runs, shipped
configuration, the same Mac and day (macOS 27.0.1, 2026-11-03), a check having finished before each
"fresh" sample; the Mac's screen was locked, so only the menu app's scenarios could run (the
Settings helper's need a window on screen), and a copy of `main` was run the same way for comparison:

| Menu app, release build | `main`, MB | With checks on and a check run, MB | Budget, MB |
|---|---|---|---|
| fresh, about 4.5 s after launch | 9.25 | 9.63 | 11 |
| after 1 menu open | 13.69 | 14.30 | 15 |
| after 10 menu opens | 14.05 | 14.59 | 15 |
| after 200 status doorbells | 8.94 | 9.31 | 11 |

The check costs about 0.4 to 0.6 MB (the URL loading stack, once a request has been made), and the
scenarios stay under their budgets, so no short-lived process is used. The headroom after 10 opens
is 0.4 MB: the next change to the menu app should repeat the rig. The Settings helper's rows
(cold start, its own footprint, closed) were not run on a locked screen; with the window created but
not on screen, the helper measured 27.99 MB against 27.75 MB for `main` (5 runs each), so the new
switch adds about 0.2 MB. Repeat the whole rig on an unlocked Mac before a release.

## Daemon decisions

How the daemon fills in what this contract leaves open (status writes, capabilities, battery
source, identity and keys, capture, Universal Control, config watching, skipped settings) is in
[How it works](how-it-works.md#status) and the invariants beside it.

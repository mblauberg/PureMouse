# Menu bar app and daemon: the contract

PureMouse is two processes in one app bundle:

- **The daemon** (`PureMouse.app/Contents/MacOS/puremouse`): headless and unchanged in identity
  (bundle ID `io.github.mblauberg.puremouse`, executable path, signature), so existing
  Accessibility and Input Monitoring grants keep matching. It alone talks to the mouse.
- **The menu bar app** (`PureMouse.app/Contents/Library/LoginItems/PureMouse Menu.app`, bundle ID
  `io.github.mblauberg.puremouse.menu`, `LSUIElement`): the status item, its menu and the Settings
  window. It needs no privacy permissions and never opens HID devices.

Either works without the other. With the menu bar app quit or hidden, the mouse behaves exactly as
configured; with the daemon stopped, the menu shows "PureMouse Is Off" and can start it.

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
- permission grant (the restart then writes a fresh one);
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
  `control.json.lock`, so a menu write already under way lands first and is deleted with it.
- `capture: {token}` with a new token starts **select by pressing**. For up to 10 s every divertable
  control of every mouse is diverted; the first press reports `{token, state: pressed, cid,
  deviceID}` and performs no action; then the normal diversion is restored. Timeout reports
  `timedOut`. Setting `capture` to nil reports `cancelled` and restores at once.
- `useConfiguredDPI: token`, when new, drops the DPI chosen by `cycleDPI` and sets every mouse to
  the config's `dpi`. The menu sends it after saving a DPI choice while a mouse reports another
  value: choosing the value already saved leaves the file unchanged, and a reload that leaves
  `dpi` alone keeps the cycled one. Every control write repeats the last token, so a later pause
  or capture cannot erase it unread; the daemon acts once per token.

### Config (menu → daemon)

The menu edits `config.json` as a JSON tree: it changes only the keys a control owns, keeps unknown
keys, and writes with `.prettyPrinted, .sortedKeys`. Before writing, it validates the whole file
with `ConfigCheck.validate`, which runs the daemon's own decoder.

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
the bundle and nothing is kept for older versions. `schema` is bumped when they change; a menu that
sees a higher `schema` shows "update PureMouse" (`AppModel.statusTooNew`). A capability member that
is missing means unknown: a reader shows the option, and hiding needs an explicit `false`.

### Device identity and capabilities (Status)

All optional; nil members are left out of the JSON.

| Field | Type | Meaning |
|---|---|---|
| `devices[].model` | String | The device key used by `devices.<key>` in the config: `m` plus the 12 lowercase hex digits of the 0x0003 model ID when the mouse reports one, else `p` plus the 4-digit lowercase hex product ID (e.g. `pb02c`). Absent when neither is known. Two mice of one model share it |
| `devices[].unit` | String | The 0x0003 unit ID as 8 lowercase hex digits, when known. Stable for one physical mouse, for per-unit state such as low-battery alerts. Never written to the config |
| `devices[].kind` | String | A word such as `mouse`, `trackball` or `keyboard`. |
| `devices[].capabilities` | object | What the mouse reports. Members: `dpi`, `smartShift`, `smoothScroll`, `thumbWheel`, `haptics`, `battery` (each Bool: true has it, false reported not to; absent unknown, e.g. a lookup that failed transiently) and `features` ([String], HID++ feature IDs in hex, for support; not filled yet). Absent until the mouse's first apply has finished |
| `devices[].controls[].gestures` | Bool | The control can report raw XY movement. Absent when unknown |
| `capture.model` | String | The device key (`devices[].model`) of the mouse whose control was pressed |

### Requests aimed at one mouse (Control)

| Field | Type | Meaning |
|---|---|---|
| `capture.device` | String | Listen on the mouse with this device key (`devices[].model`) only. Absent means every mouse |
| `device` | String | Qualifies `useConfiguredDPI`: set only the mouse with this device key to the config's `dpi`. Absent means every mouse |


## New config keys

| Key | Type | Meaning |
|---|---|---|
| `smoothScroll.enabled` | Bool, default true | false keeps the tuning but scrolls natively (wheels not diverted) |
| `dpiPresets` | [Int], 0–8 entries, each within `Config.dpiRange` | shown in the menu; cycled by `cycleDPI` |
| action `cycleDPI` | action name | next preset after the current DPI, wrapping. Live only: kept across reconnects, cleared when a reload changes `dpi` or `dpiPresets` |

## Login and lifecycle

The daemon CLI owns every launchd change (`LoginItem.swift` holds the policy; a `LoginService`,
`LaunchdAgentService`, holds the mechanism, so the policy is tested against a fake). The menu
app runs these commands through the daemon binary at `Bundle.main.bundleURL/../../../MacOS/puremouse`.

"Starts at login" and "is running now" are separate, and each command changes only the axis the
table gives:

| Command | Starts at login | Running now |
|---|---|---|
| `puremouse login on` | on | unchanged |
| `puremouse login off` | off | unchanged (a running job stays loaded until logout or `stop`) |
| `puremouse start` | unchanged | on (daemon, and menu unless hidden) |
| `puremouse stop` | unchanged | off |
| `puremouse register` / `unregister` | on / off | restarted / off |

| Command | Effect |
|---|---|
| `puremouse register` | writes and boots both agents (daemon `KeepAlive`; menu `RunAtLoad`, `KeepAlive: {SuccessfulExit: false}`, `MallocSpaceEfficient`), unless the menu is hidden. Prints the outcome |
| `puremouse unregister` | boots out both agents and removes both plists |
| `puremouse login on` / `off` | writes both plists (the menu's unless hidden) without booting anything, or removes both without booting anything out. A running agent is left as it is |
| `puremouse start` | starts the agents that have no process (the menu's unless hidden) and leaves running ones alone: a job that is not loaded is bootstrapped, one that is loaded without a process (the menu after Quit) is kickstarted, or booted out and bootstrapped again when the executable `launchctl print` shows for it is not this copy's. A registered job's plist is first rewritten for this copy of the app, so a moved app does not start from the old path; it stays registered. An agent that is not registered runs from a plist in `launchd/` under `Companion.directory`, which launchd does not load at the next login and which stays there until `stop` removes it |
| `puremouse stop` | boots out both agents but keeps their plists: **Quit PureMouse**. Both start again at login if registered |
| `puremouse menu on` / `off` | writes and boots, or boots out and removes, the menu agent only: **Show in menu bar** / **Hide Menu Bar Icon** |
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
job started with `start` while unregistered reads `notRegistered`. The menu app reads its "starts
at login" answer from it rather than looking for a plist file.

Opening PureMouse.app from the Finder runs `register`, touches `show-settings` in
`Companion.directory` and opens the menu app, which shows Settings; with the icon hidden it quits
when Settings closes. `open` is tried twice, since it can reach the instance `register` is booting
out and fail (`_LSOpenURLsWithCompletionHandler` error -600). The old alert is kept only when
there is no menu app or it cannot be opened. The menu app keeps a single instance: a second launch
touches `show-settings`, posts `io.github.mblauberg.puremouse.menu.show` and exits, and the running
one shows Settings. An instance that starts within 5 s of that stamp (including one launchd starts)
shows Settings too and removes it, so a request made while the agent restarts is not lost. Reopening
the app (`applicationShouldHandleReopen`) also shows Settings. If the user has blocked the item
under System Settings › Menu Bar, opening the app still reaches Settings.

## Footprint

The daemon's budget is unchanged: zero CPU while idle, about 10 MB. The menu app must use zero CPU
while idle, with no timers or polling. Its footprint is `phys_footprint` from `footprint(1)`, and
the figures below are medians of 5 runs of `scripts/measure-menu.sh` (`docs/development.md`,
"Footprint rig") on a spare Mac, macOS 27.0.1, arm64, on 2026-11-02. They move with the OS, so
read them as "about" and repeat the rig after each macOS release. The bare AppKit column is
`scripts/measure-bare-appkit.sh` (5 runs, the same Mac and day).

| Menu app, release build | Without the variable, MB | Shipped (`MallocSpaceEfficient=1`), MB | Bare AppKit status item and menu, same Mac |
|---|---|---|---|
| fresh, about 4.5 s after launch | 13.8 | 10.1 | 10.8 |
| after 1 menu open | 19.8 | 14.1 | 15.2 |
| after 3 menu opens | 19.9 | 14.1 | 15.4 |
| after 10 menu opens | 19.9 | 14.2 | 15.6 |
| after 200 status doorbells, 10 ms apart, menu never opened | 13.8 | 10.0 | |
| Settings open, in this process | 43.1 | 33.9 | |
| Settings closed again, in this process | 38.9 | 24.9 | |

The shipped column is the rig, which passes on the Info.plist's `LSEnvironment` (the agent's plist
sets the same variable); the other column is main's build without it (same Mac, same day).
After 3 opens that is 0.71 times the baseline, and fresh is lower, which passes the adoption rule
(at most 0.75 times, fresh no worse).

What the numbers say:

- **The first menu open costs about 4 to 6 MB, once.** Later opens add almost nothing (14.1 to 14.2 MB
  over ten, shipped; 19.8 to 19.9 without the variable). A bare `NSStatusItem` with an `NSMenu` and nothing else grows by about 4 MB on its first
  open (10.8 to 15.2 MB), so most of the cost is AppKit's, not the menu's; the rest is ours.
- **Status updates did not grow it.** 200 doorbells posted 10 ms apart, `status.json` changed
  before each, left the fresh figure where it was (10.0 against 10.1 MB shipped; 13.8 against 13.8 without the variable).
- **No growth was seen across the measured opens and doorbells.** The earlier question was a
  repeating 272 KB block per open. It was not reproduced: after 30 opens under
  `MallocStackLogging`, `heap -addresses=all` listed no live block of that size (the largest live
  block was 64 KB), so no owner could be named. One run on 2026-11-02, with
  `scripts/measure-menu.sh --blocks`.
- **Settings is where the rest goes.** Opening it adds about 24 MB (29 without the variable), and closing it gives back only
  about 9 MB (4 without), even after `malloc_zone_pressure_relief`: AppKit and SwiftUI keep the pages. Hence
  `Relaunch`: once Settings has closed, the app starts over as a fresh copy (the "closed" row above
  is the process without that restart; the rig does not restart it).
- **Allocator.** The growth was freed small-malloc pages that stay resident and that
  `malloc_zone_pressure_relief` does not return. The menu app runs with
  `MallocSpaceEfficient=1` (a preference for reusing freed space over speed), in its launchd
  environment and, for a launch by the Finder, `LSEnvironment` in its Info.plist. The gate ran on the
  branch build against main's, five runs each, side by side: 14.1 against 19.9 MB after 3 opens
  (0.71 times) and 10.1 against 13.8 fresh. The variable is undocumented, so a macOS release may
  ignore it; the rig is repeated after each one.
- **The prefs-domain caveat.** For a while the rig's numbers were bimodal: some launches started
  about 4 MB higher, even for the fresh and doorbell scenarios, and a fresh bundle id or
  `defaults delete` of the rig's domain brought them back. The cause is a transient state of the
  preferences domain that we could not reproduce on demand, so the rig clears its domain before
  every launch. An installed app that carries that state may read several MB above these figures.

The Settings window and its view tree are created when shown. Once Settings has closed, the app
starts over as a fresh copy (`Relaunch`): the agent's copy exits with 75 (EX_TEMPFAIL) and launchd
restarts it (`KeepAlive` unless successful) within a second, in the same place in the menu bar; it
waits until 11 s after its own start (launchd's respawn throttle), and while the menu is open or a
lifecycle command runs. A copy the Finder started (the icon was hidden, then shown again in
Settings) exits and has launchd start the agent, so the icon is supervised again. `exec` in place
does not work: LaunchServices keeps the old image's registration for the pid and the new image
never gets its status item. The menu itself is a plain `NSMenu` built on open (`menuNeedsUpdate`).
`scripts/measure-menu.budgets` holds the limits the rig checks; measure with the rig, or
`footprint`/`vmmap --summary`, before and after each change.

## Daemon decisions

Choices the contract left open, as the daemon implements them:

- **Status.** A write is skipped when nothing in `Status` changed. `Device.id` is
  `<interface number>-<device index>`, the interface numbered in attach order. `dpiSteps` lists
  every value (157 on an MX Master 3S). `controls` leaves out virtual controls (flag 0x80, e.g.
  0x00d7), which cannot be pressed. While paused, `devices` is empty: the sessions are dropped.
- **Battery** comes from HID++ 0x1004 (getStatus, then its broadcast events). `charging` is true
  while charging or charging slowly, false once complete. As in Linux, the level bits are masked
  by getCapabilities and the highest wins; a mouse that reports a percentage has its levels
  ignored, so `level` is derived from the percentage. Mice without 0x1004 fall back to
  the older 0x1000 (its status, then its broadcast events), whose percentage of 0 means unknown.
- **Config watching** watches the file as well as its directory, since editors that write in place
  leave the directory unchanged. A reload that fails leaves the previous config in effect and
  reports `config.error` (`ConfigCheck.message`, which names the field); the next successful load
  clears it.
- **cycleDPI** picks the smallest preset above the current DPI, else the smallest, after snapping
  the presets to the sensor's list. With no `dpiPresets` it does nothing and logs an error.
- **Universal Control.** `away` is true while the pointer is on another Mac and
  `universalControl.handOff` is on: each session keeps its settings but leaves the wheels and
  controls native (`Session.setAway`). Going away cancels a listening capture. The menu shows "On
  another Mac" in the device line.
- **Capture.** Only controls not already bound are diverted for it (bound ones already reach the
  daemon). A capture still listening when the config reloads or the daemon pauses reports
  `cancelled`. A mouse adopted during a capture joins it; one lost during it simply drops out.
  The daemon acts on a capture token once, so rewriting `control.json` with the same token does
  not restart it. With `capture.device`, only mice with that key listen, and only they join when
  adopted during it; a mouse with no key is reached only by a request without `device`.
- **Identity.** Read once per adoption (`Identification.read`): the name (0x0005), kind (0x0005
  getDeviceType), and model and unit IDs (0x0003). A mouse whose 0x0003 answers with an error, or
  that lacks it, is keyed by its product ID: the interface's for Bluetooth, the slot's wireless
  product ID on a receiver. A 0x0003 that times out leaves `model` absent rather than guess, and that
  mouse uses the top-level settings. A model ID of all zeros or all 0xFF counts as absent, as does
  such a unit ID. The key is in the adoption log line (`model=`). Two mice of one model share a key,
  so they share `devices.<key>` and are both reached by a `device` request.
- **Capabilities** come only from lookups apply has already made (`HIDPPDevice.knownPresence`), so
  building them sends nothing; apply also looks up haptics (0x19B0). A member is true when its
  feature is present, false when known absent (`smartShift`: both 0x2110 and 0x2111; `battery`:
  both 0x1004 and 0x1000), and left out when a lookup failed. They are kept across reloads.
  `controls` lists only divertable, non-virtual controls, and `gestures` follows the control's
  raw-XY flag. `schema` is 2.
- **Settings per mouse.** Each session gets `Config.forDevice(model)`, at adoption and on reload. A
  reload keeps a mouse's live DPI unless its own resolved `dpi` or `dpiPresets` changed. A setting
  the mouse cannot use is skipped quietly: a bound control it lacks is a debug line once per
  session, `toggleScrollMode` without SmartShift and smooth scrolling without 0x2121 an info line
  once per session, and a DPI snapped to the sensor's list is logged once per mouse, not per reload.
- **Login.** "Hidden" is remembered by a `menu-hidden` file in `Companion.directory`, written by
  `menu off` and removed by `menu on`; `unregister` keeps it. The CLI calls `setsid()` and boots
  the menu agent out last, after removing its plist, because launchd kills the menu job's process
  group (which includes the CLI it spawned). When the menu bar app itself runs `register` or
  `menu on` and its agent is already loaded, the agent is left running (the plist is still
  rewritten); restarting it would quit the caller.

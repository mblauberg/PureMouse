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

### Status (daemon → menu)

The daemon rewrites `status.json` when anything in it changes:

- start;
- each device adopted, lost, woken or asleep;
- battery change;
- DPI or wheel-mode change;
- permission grant (the restart then writes a fresh one);
- config load or failure;
- pause or resume;
- capture progress;
- shutdown, which sets `running: false` as its last act after restoring the mice.

Writes are coalesced on the main queue, at most one per run-loop turn.

The menu treats the daemon as running when `running` is true and `kill(pid, 0)` succeeds. A
missing or stale file means "PureMouse Is Off".

### Control (menu → daemon)

- `paused: true`: every session is restored to native behaviour (`Session.restore()`, wheels first),
  sessions are dropped and adoption stops. `paused: false` re-adopts connected mice and applies the
  config. Pausing is not persisted: the daemon deletes `control.json` at start.
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

The daemon watches the config's directory with a `DispatchSource` (the file is replaced atomically,
so the file's own descriptor goes stale). It reloads when the file's bytes change, debounced
about 150 ms, exactly as for SIGHUP. Hand edits therefore apply on save. A failed load keeps the
previous config and reports `config.error`.

Slider writes from the menu are debounced to about 300 ms.

## New config keys

| Key | Type | Meaning |
|---|---|---|
| `smoothScroll.enabled` | Bool, default true | false keeps the tuning but scrolls natively (wheels not diverted) |
| `dpiPresets` | [Int], 0–8 entries, each within `Config.dpiRange` | shown in the menu; cycled by `cycleDPI` |
| action `cycleDPI` | action name | next preset after the current DPI, wrapping. Live only: kept across reconnects, cleared when a reload changes `dpi` or `dpiPresets` |

## Login and lifecycle

The daemon CLI owns every launchd change (`LoginItem.swift`). The menu app runs these commands
through the daemon binary at `Bundle.main.bundleURL/../../../MacOS/puremouse`:

| Command | Effect |
|---|---|
| `puremouse register` | writes and boots both agents (daemon `KeepAlive`; menu `RunAtLoad`, `KeepAlive: {SuccessfulExit: false}`), unless the menu is hidden. Prints the outcome |
| `puremouse unregister` | boots out both agents and removes both plists |
| `puremouse stop` | boots out both agents but keeps their plists: **Quit PureMouse**. Both start again at login |
| `puremouse menu on` / `off` | writes and boots, or boots out and removes, the menu agent only: **Show in menu bar** / **Hide Menu Bar Icon** |

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
while idle, with no timers or polling. Its target is under 25 MB resident with Settings closed;
the Settings window and its view tree are created when shown and released when closed. The menu
itself is a plain `NSMenu` built on open (`menuNeedsUpdate`). Measure both apps with
`footprint`/`vmmap --summary` before and after each change.

## Daemon decisions

Choices the contract left open, as the daemon implements them:

- **Status.** A write is skipped when nothing in `Status` changed. `Device.id` is
  `<interface number>-<device index>`, the interface numbered in attach order. `dpiSteps` lists
  every value (157 on an MX Master 3S). `controls` leaves out virtual controls (flag 0x80, e.g.
  0x00d7), which cannot be pressed. While paused, `devices` is empty: the sessions are dropped.
- **Battery** comes from HID++ 0x1004 (getStatus, then its broadcast events). `charging` is true
  while charging or charging slowly, false once complete. As in Linux, the level bits are masked
  by getCapabilities and the highest wins; a mouse that reports a percentage has its levels
  ignored, so `level` is derived from the percentage. Mice without 0x1004 report none; the older
  0x1000 is not read.
- **Config watching** watches the file as well as its directory, since editors that write in place
  leave the directory unchanged. A reload that fails leaves the previous config in effect and
  reports `config.error` (`ConfigCheck.message`, which names the field); the next successful load
  clears it.
- **cycleDPI** picks the smallest preset above the current DPI, else the smallest, after snapping
  the presets to the sensor's list. With no `dpiPresets` it does nothing and logs an error.
- **Capture.** Only controls not already bound are diverted for it (bound ones already reach the
  daemon). A capture still listening when the config reloads or the daemon pauses reports
  `cancelled`. A mouse adopted during a capture joins it; one lost during it simply drops out.
  The daemon acts on a capture token once, so rewriting `control.json` with the same token does
  not restart it.
- **Login.** "Hidden" is remembered by a `menu-hidden` file in `Companion.directory`, written by
  `menu off` and removed by `menu on`; `unregister` keeps it. The CLI calls `setsid()` and boots
  the menu agent out last, after removing its plist, because launchd kills the menu job's process
  group (which includes the CLI it spawned). When the menu bar app itself runs `register` or
  `menu on` and its agent is already loaded, the agent is left running (the plist is still
  rewritten); restarting it would quit the caller.

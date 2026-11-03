# 9. Settings is an on-demand helper app

## Status

Accepted

## Context

The menu bar app links AppKit and SwiftUI. Opening Settings in-process leaves 27-30 MB resident
after it closes (measured), so today the process starts over when Settings closes (`Relaunch`):
exit 75 for launchd to restart it, a wait until 11 s after launch for launchd's throttle, a
different path for copies the Finder started, and relaunch calls in four places. Settings also has no Dock icon or Cmd-Tab entry,
because the menu app is an accessory app.

## Decision

Settings becomes `PureMouse Settings.app` in `Contents/Helpers/`, a regular app with its own
identifier (`io.github.mblauberg.puremouse.settings`), started by the menu with `NSWorkspace` and
exiting when its window closes. Pure logic and the file contract live in a shared library
([ADR 11](0011-shared-logic-library.md)), and the menu target no longer links SwiftUI.

## Alternatives rejected

- Keep `Relaunch`: works, but costs the throttle wait, icon flicker and four coupling sites, and
  leaves SwiftUI resident.
- Rewrite Settings in AppKit and keep one process: about 3,500 lines of panes for weeks of work,
  and AppKit alone still leaves residue.
- Allocator tuning alone: measured, `malloc_zone_pressure_relief` returns 3 MB of the 30 and
  `MallocSpaceEfficient` 10 MB ([ADR 10](0010-menu-memory-budgets.md)).

## Consequences

- No residue by construction; Dock and Cmd-Tab come free; `Relaunch` and its couplings go.
- A third nested bundle: about 3.3 MB more installed (11.6 MB against 8.3 MB) and 2.4 MB more
  download, 1.8 MB of each for its own copy of the adaptive icon (`Assets.car`), which is what
  draws its Dock and Cmd-Tab icon in the dark, clear and tinted styles; one more entry in
  `scripts/lib.zsh`'s `components`, and budgets re-measured.
- A cold start at "Settings…" (budget 1 s), and two processes writing the config, which both take
  an advisory lock on `config.json.lock` for the whole read-merge-replace.
- Opening the app from the Finder and `puremouse register` must open the helper.

## Amendment: one name

The helper's display name (`CFBundleDisplayName`, and the app menu's About, Hide and Quit items) is
"PureMouse", the name people know the app by, not "PureMouse Settings" (#146). The menu bar app's
launcher alerts say "PureMouse can't find Settings." and "PureMouse couldn't open Settings.".

Identity stays separate. The bundle folder `PureMouse Settings.app`, the identifier
`io.github.mblauberg.puremouse.settings` and `SettingsLookup.appName` do not change, so nothing keyed
on the identifier, and no path in the daemon, moves. Only what macOS shows (the Dock, Cmd-Tab and the
app menu) takes the display name. The name is set in `scripts/lib.zsh#write_info_plist` and checked
by `scripts/tests/test_bundle.zsh`.

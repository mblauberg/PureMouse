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
- A third nested bundle: about 2 MB more, one more entry in `scripts/lib.zsh`'s signing list, and a
  line in the size budget.
- A cold start at "Settings…" (budget 1 s), and two processes writing the config, which both take
  an advisory lock on `config.json.lock` for the whole read-merge-replace.
- Opening the app from the Finder and `puremouse register` must open the helper.

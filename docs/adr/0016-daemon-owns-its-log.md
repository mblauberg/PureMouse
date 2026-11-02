# 16. The daemon owns its log file

## Status

Accepted

## Context

launchd wrote the daemon's stderr to `~/Library/Logs/PureMouse.log` through `StandardErrorPath` in
the agent plist. launchd held the descriptor, so the daemon could not rotate or reopen the file, and
a plist bundled inside the app (needed for `SMAppService`,
[ADR 18](0018-login-service-seam.md)) cannot name a path in the user's home. The menu app's own log
(`PureMouse Menu.log`) held nothing the menu wrote itself.

## Decision

When `puremouse run` starts with stderr not a terminal, `LogFile.attachStderr`
(`Sources/puremouse/Log.swift`) opens the log with `O_APPEND|O_CREAT`, creating its directory, and
moves it onto stderr. The agent plists no longer set `StandardErrorPath`, and the menu's log is dropped.

## Alternatives rejected

- Rewriting a per-user plist at each login: defeats bundled plists.
- `os_log`: users and the issue forms rely on a plain text file.

## Consequences

- One process owns the file, so rotation ([ADR 7](0007-log-rotation.md)) is a local operation.
- The log path and line format are unchanged; a run from a terminal still prints there and creates
  no file.
- Leftover `PureMouse Menu.log` files are harmless.
- An agent registered by an older build still has `StandardErrorPath`; registering again (which
  opening the app does) rewrites its plist. Nothing in the code handles the old plist.

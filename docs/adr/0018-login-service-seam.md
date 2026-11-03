# 18. Start at login behind a `LoginService` seam

## Status

Proposed for the `SMAppService` migration only, which is gated by a spike on a Developer ID build
across an update. The `LoginService` seam with launch agents is built (`LoginService`,
`LaunchdAgentService`, `puremouse login-status`, `login on|off`, `start`).

## Context

`Sources/puremouse/LoginItem.swift#LoginItem` writes launch agent plists with absolute paths into
`~/Library/LaunchAgents`. They survive dragging the app to the Bin, and the code mixes mechanism,
policy and UI, so none of it is testable. Without a Developer ID team, launchd pins `SMAppService`
agents to the build that registered them, so an update fails to start (EX_CONFIG). With a Team ID,
`SMAppService` keeps the plists inside the bundle and lists them under the app in Login Items, but
re-registering from another build may not update, and changing the signing identifier breaks
upgrades.

## Decision

`LoginItem` keeps its policy (daemon before menu, menu removed last, the hidden-menu marker, which keeps the menu agent and drops only its icon, the
caller's own agent left running) and talks to a `LoginService`. Launch agents implement it. An
`SMAppService.agent` implementation is chosen when the running binary has a Team ID and the bundled
plists exist, if the spike passes; otherwise launch agents stay for Developer ID builds too. The CLI
reports login state, so the menu reads it from the CLI, not from a plist file.

## Alternatives rejected

- `SMAppService.loginItem` for the menu: loses `KeepAlive` crash recovery, `XPC_SERVICE_NAME`
  detection and `launchctl kickstart`.
- `SMAppService.mainApp`: launches the daemon through LaunchServices with no supervision and no
  restart when a permission is granted.

## Consequences

- The seam names a job by what to run (the daemon's executable, the menu app's bundle) and never
  carries a launchd plist, so the plist, its `MallocSpaceEfficient` setting and its `launchctl`
  verbs stay in `LaunchdAgentService`, which has tests of its own against a scripted `launchctl`.
- Every command that changes what is registered or running takes one file lock in the companion
  directory (30 s wait, then a clear error), so a `stop` and a `start` that overlap run in order.
- Two implementations to keep once `SMAppService` is added; the launch-agent one is small.
- Login Items shows an entry the user can switch off, which `register` must handle.
- `docs/companion.md` ("Login and lifecycle") is rewritten when `SMAppService` lands.

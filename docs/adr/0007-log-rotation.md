# 7. Size-capped log rotation in the daemon

## Status

Accepted

## Context

`~/Library/Logs/PureMouse.log` grew without bound: launchd appended the daemon's stderr to it and
nothing rotated it.

## Decision

The daemon rotates its own log, which it owns ([ADR 16](0016-daemon-owns-its-log.md)). Once the
log passes 1 MiB, it renames it to `PureMouse.log.1` (replacing an older one) and starts a new
`PureMouse.log`. The check runs at start and on writes, never on a timer. A run from a terminal
writes no log, so it never rotates.

## Alternatives rejected

- `newsyslog`: needs a root-owned config and an installer step.
- `os_log`: users, the troubleshooting guide and the issue forms rely on a plain text file.
- Truncating in place: loses the most recent context.

## Consequences

- At most about 2 MiB of log on disk.
- A rotation happens between whole lines, so no line is split or lost.
- Only the daemon's own lines are counted, so `run` commands get /dev/null for their output, and
  a failed one is logged once.

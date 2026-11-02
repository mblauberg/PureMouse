# 7. Size-capped log rotation in the daemon

## Status

Accepted

## Context

`~/Library/Logs/PureMouse.log` grew without bound: launchd appended the daemon's stderr to it and
nothing rotated it.

## Decision

The daemon rotates its own log, which it owns ([ADR 16](0016-daemon-owns-its-log.md)). It counts
the bytes written, starting from the file's size at launch. Once a write takes the count past
1 MiB, and only while stderr is that file, it renames the file to `PureMouse.log.1` (replacing an
older one), opens a new `PureMouse.log` and moves stderr onto it. A lock covers the check, and a
run from a terminal never rotates. The check runs at start and after writes, never on a timer.

## Alternatives rejected

- `newsyslog`: needs a root-owned config and an installer step.
- `os_log`: users, the troubleshooting guide and the issue forms rely on a plain text file.
- Truncating in place: loses the most recent context.

## Consequences

- At most about 2 MiB of log on disk.
- A rotation happens between whole lines, so no line is split or lost.
- Output of child processes that inherit stderr is not counted; it is small and short-lived.

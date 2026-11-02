# 2. Feature absence is cached per endpoint, and capabilities come from that cache

## Status

Accepted, not built

## Context

A feature the mouse lacks is looked up again on every apply, action and restore, and each lookup
is a round trip (slow over Bluetooth). Caching absence per session was suggested, but the cache of
feature indices already outlives sessions.

## Decision

`HIDPPDevice` caches a definite absence (the root feature answers index 0) beside its index cache,
for the endpoint's lifetime. Timeouts and errors are never cached. The cache is exposed as known
presence, and the capability map the daemon publishes (see
[ADR 4](0004-device-identity-and-companion-contract.md)) is derived from it only after a
successful apply.

## Alternatives rejected

- Per-session caching: cleared on every reload while the index cache is not, so the two lifetimes
  would differ for no gain.
- Enumerating every feature (0x0001) at adoption: about 30 extra requests on each Bluetooth wake.

## Consequences

- Clearing either cache needs a new endpoint (a receiver slot change or Bluetooth reattach), as
  indices already do. A firmware update while the daemon runs is picked up after a replug or
  restart.
- AGENTS.md's per-session haptic absence rule is reworded to the endpoint cache when this lands.

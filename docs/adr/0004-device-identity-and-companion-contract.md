# 4. Device identity (`m<model>` / `p<pid>`); the status contract is versioned with the bundle

## Status

Accepted, not built

## Context

Per-device settings need a key that survives reconnects, a switch between receiver and Bluetooth,
and daemon restarts. `Status.Device.id` (interface and index) does not. The menu bar app and the
daemon ship in one bundle and are never run apart, and before 1.0 the owner engineers nothing for
backward compatibility (decision of 2026-11-02).

## Decision

- The device key is `m` plus the model ID in hex from feature 0x0003 when the mouse has it, else
  `p` plus the product ID in hex as IOKit or the receiver reports it (for example `pb02c`). Keys
  are validated by `ConfigCheck`.
- When 0x0003 is absent, the same model over Bolt and over Bluetooth may get different keys. This
  is documented, not aliased.
- The status gains the key, the device kind and a capability map. Capability values are tri-state
  on the wire: `true` or `false` only when definitive, the key omitted when unknown (including a
  transient lookup failure).
- The status format is versioned with the bundle: it changes freely before 1.0, `schema` is bumped
  when its shape changes, and the release notes say so. `docs/companion.md` describes the current
  shape.

## Alternatives rejected

- The device name as key: readable, but not guaranteed unique or stable across firmware. It stays
  as the informational `name`.
- An additive-only contract tested against a frozen 0.3.0 reader: compatibility work for a pre-1.0
  app whose menu and daemon never run apart.

## Consequences

- Two identical mice share settings (documented).
- Two requests are added to each adoption.
- The key format is the one irreversible choice in the config file, so it was approved by the owner.

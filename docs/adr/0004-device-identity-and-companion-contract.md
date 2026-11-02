# 4. Device identity and an additive companion contract

## Status

Accepted

## Context

Per-device settings need a key that survives reconnects, a switch between receiver and Bluetooth,
and daemon restarts. `Status.Device.id` (interface and index) does not. The menu bar app decodes
all of `status.json` or nothing, with strict enums, so a careless change breaks older menus.

## Decision

- The device key is `m` plus the model ID in hex from feature 0x0003 when the mouse has it, else
  `p` plus the product ID in hex as IOKit or the receiver reports it (for example `pb02c`). Keys
  are validated by `ConfigCheck`.
- When 0x0003 is absent, the same model over Bolt and over Bluetooth may get different keys. This
  is documented, not aliased.
- The status gains the key, the device kind and a capability map. Capability values are tri-state
  on the wire: `true` or `false` only when definitive, the key omitted when unknown (including a
  transient lookup failure).
- Every addition is optional and `schema` stays 1. The additive rule (new fields optional, nothing
  removed or retyped, no new cases in existing enums) is written into `docs/companion.md` and
  tested against a frozen copy of the 0.3.0 status types.

## Alternatives rejected

- The device name as key: readable, but not guaranteed unique or stable across firmware. It stays
  as the informational `name`.
- Bumping `schema`: every 0.3.x menu would ask for an update over purely additive data.

## Consequences

- Two identical mice share settings (documented).
- Two requests are added to each adoption.
- The key format is the one irreversible choice in the config file, so it was approved by the owner.

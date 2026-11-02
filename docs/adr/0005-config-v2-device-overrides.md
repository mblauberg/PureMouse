# 5. Config v2 is additive per-device overrides, with no migration

## Status

Accepted

## Context

An in-place migration to a `defaults` wrapper plus `devices.<model>` was proposed. The config file
is edited by hand, the menu keeps keys it does not know, and older and newer daemon and menu
pairings must keep working.

## Decision

The top-level keys are the defaults. `devices.<key>` (the key from
[ADR 4](0004-device-identity-and-companion-contract.md)) holds overrides with the same section
shapes. Precedence is top level, then `devices.<key>`, then `apps.<bundleId>`, each merged per
leaf as `apps` already is. The Kit decoder resolves each device entry at load, and
`ConfigCheck.validate` stays the only decoder. The menu's scopes follow the same paths
([ADR 12](0012-multi-device-settings-scopes.md)).

## Alternatives rejected

- A `defaults` wrapper with a migration: it rewrites users' files (losing their order and layout),
  needs a backup and rollback story, older daemons cannot read the result, and it is a one-way door
  with no gain in what can be expressed.

## Consequences

- No migration code and no backup files; a version 1 file is a valid version 2 file.
- Downgrading keeps working: an older daemon ignores `devices` and applies the defaults, and an
  older menu keeps the unknown key and edits the defaults.
- `devices.<key>.apps` nesting is left out until someone asks for it.

# 5. Config v2 is per-device overrides on top-level defaults, with no migration

## Status

Accepted. The decoder and the daemon apply `devices` (`Config+Devices.swift`,
`Config.forDevice`); Settings does not write it yet ([ADR 12](0012-multi-device-settings-scopes.md)).

## Context

Per-device settings need a place in the config file. An in-place migration to a `defaults`
wrapper plus `devices.<model>` was proposed. The config file is edited by hand, and the menu keeps
keys it does not know.

## Decision

The top-level keys are the defaults. `devices.<key>` (the key from
[ADR 4](0004-device-identity-and-companion-contract.md)) holds overrides with the same section
shapes. Precedence is top level, then `devices.<key>`, then `apps.<bundleId>`, each merged per
leaf as `apps` already is. The Kit decoder resolves each device entry at load, and
`ConfigCheck.validate` stays the only decoder. The menu's scopes follow the same paths
([ADR 12](0012-multi-device-settings-scopes.md)). There is no `defaults` wrapper and no migration.

## Alternatives rejected

- A `defaults` wrapper with a migration: it rewrites users' files (losing their order and layout),
  needs a backup and rollback story, and adds nothing that can be expressed.

## Consequences

- It is the simplest design: no migration code and no backup files, and a file without `devices`
  is already valid.
- `devices.<key>.apps` nesting is left out until someone asks for it.

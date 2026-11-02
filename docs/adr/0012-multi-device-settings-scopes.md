# 12. Multi-device Settings: path-prefix scopes with per-leaf fallback

## Status

Accepted

## Context

The config format puts the defaults at the top level, device overrides under `devices.<key>` and
app settings on top ([ADR 5](0005-config-v2-device-overrides.md)). Settings must edit any of these
without hiding what is inherited.

## Decision

A scope is a path prefix: `[]` for every mouse, `["devices", key]` for one. Reads fall back per leaf
to the top level, mirroring the daemon's merge, and a test checks the result against Kit's decoder.
Writes go to the selected scope only. One Mouse tab carries a device menu (All Mice, then each
known mouse), shown when two or more mice are known or a `devices` entry exists.

## Alternatives rejected

- A tab per device: the tab bar grows without limit and shared sections have no home.
- Copy-on-select, writing every key into the device entry: breaks "inherit until changed" and bloats
  the file.

## Consequences

- Single-mouse users see no change and no new keys.
- Older menus keep working: they keep the unknown `devices` key and edit the defaults.
- Buttons, Scrolling and Pointer rows gain per-row inheritance logic.

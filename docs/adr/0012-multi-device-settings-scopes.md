# 12. Multi-device Settings: path-prefix scopes with per-leaf fallback

## Status

Accepted and built. The `ConfigTree` half (`ConfigScope`, `resolved`, `isOverridden`,
`set(_:at:in:)`, `deviceEntries`, and a parity test against `Config.forDevice`) came first; the
pop-up (`MousePopUp`, `MouseScope`) and the per-row inheritance in the Buttons, Scrolling and
Pointer panes (`InheritedValue`, as for apps) followed (#54). The Apps note sits in the pop-up's
menu rather than under it, for the height budget, with one more note there: "Settings you don't
change follow All Mice." A row that inherits looks as it does under All Mice; only a row with its
own value is marked ("Set for this mouse." and a "Use All Mice Setting" link). A mouse can choose
Mouse Default for a button All Mice binds: Kit reads the reserved `buttons` value `"default"` (not an
action) as no binding, which a device entry or an app layers over the wider scope's binding, so the
mouse's own behaviour applies there. That behaviour is what the daemon performs for the control
(`Config.nativeBehaviour(of:)`): a native click for the wheel click, back and forward; the
wheel-mode switch for the top button; DPI cycling for the DPI button. Controls with none (the
gesture button, the thumb panel) are not offered Mouse Default on a mouse or in an app. The picker
keeps "Same as All Mice" (removes the key) and Mouse Default (writes `"default"`) as separate
choices, and hides Mouse Default where the wider scope already is it. Settings reads and writes
button aliases as Kit does (the last name in sorted order), and giving a button back removes
every alias.

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
- Buttons, Scrolling and Pointer rows gain per-row inheritance logic.
- A mouse keyed by product ID alone can get another key over Bolt than over Bluetooth once 0x0003
  answers: documented, not aliased.

# 24. One action model: triggers per control, actions as values

## Status

Accepted, not built. Epic #155 builds it in slices (with #153 and #154); each slice moves its part
of the rules into `docs/configuration.md`, and until then the shipped config is unchanged.

## Context

Buttons bind one action, the gesture button binds a click and four directions, and more behaviour
is wanted on the same controls: double-click, hold, button plus scroll, modifier plus scroll,
sequences, an action ring, per-app actions. Each added as its own mechanism would grow the config
and the picker with no common rule for scopes. The config is also the hand-editable API.

## Decision

- A binding is a bare action, which is its click, or a flat trigger table:
  `{click, doubleClick, hold | up/down/left/right | scroll}`. Today's gesture object is already
  this table, so it stays valid.
- One hold form per button: Hold, Hold and Move (`up`, `down`, `left`, `right`) or Hold and Scroll
  (`scroll`). Choosing one replaces the others, and `ConfigCheck` rejects a table with two.
- Each trigger inherits on its own, All Mice then the mouse then the app. A bare action replaces
  the whole binding. `"none"` turns a trigger off in that scope. A ring or sequence is replaced
  whole and never merged.
- Ring and Sequence are actions, so they work on any trigger. `modifiers.<key>.scroll` replaces
  `shiftScrollsHorizontally`, with no compatibility reader before 1.0.
- Config-only knobs, each ranged: `holdMs` 150-1000 (350), `doubleClickMs` 150-1000 (the system
  interval), `ignoreRepeatedClicks.ms` 20-200 (60).
- Limits: a sequence has 1-8 steps, each wait 0-2000 ms, 10 s in all, with no loops, nesting or
  while-held steps. A ring has 2-8 one-shot actions or sequences, with no nested rings.
- No chords, press sequences or conditions.

## Alternatives rejected

- A `rules` array of when/on/do entries: exact and general, but nobody can read or edit it by hand.
- Several hold forms on one button: combining them starts a rule engine.
- A "Several Actions" picker value: it hides what a click does. The pop-up always shows the click.

## Consequences

- Every shipped form stays valid except `shiftScrollsHorizontally`. `ConfigGoldenTests` is
  regenerated on purpose in the slice that folds it in, and the release notes say so.
- The daemon compiles each control's plan on config load, so an unused trigger costs nothing and a
  bare action behaves as today.
- UI and words: [ui-design](../ui-design.md#planned-structure-155) and
  [ui-language](../ui-language.md#planned-155).

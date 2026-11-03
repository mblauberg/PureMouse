# Configuration

Settings and hand edits share one file, `~/.config/puremouse/config.json`. Every field is optional;
anything left out takes its value from the [default set](#defaults). PureMouse creates no file: with
none, it runs the default set, and a file holds only what you changed. A short example
([`config.example.json`](../config.example.json) documents the format and is checked to decode, but is not a
recommended setup):

```json
{
  "dpi": 1600,
  "smoothScroll": { "speed": 0.8 },
  "buttons": {
    "gesture": { "click": "missionControl", "left": "spaceLeft", "right": "spaceRight" },
    "back": "navigateBack",
    "forward": "navigateForward",
    "middle": "toggleScrollMode"
  }
}
```

PureMouse watches the file and applies changes when you save it. A file that does not load is
reported in the log and in Settings, and the previous settings stay in effect. Settings changes
only the keys it shows and keeps any others. Reset All Settings and Restore Last Working (General)
replace the whole file, so they first keep it as `config.json.bak` beside it (beside the target
when the config is a symlink), replacing an earlier backup; a missing or empty file (`{}`) keeps
no backup and leaves an earlier one alone. If the backup cannot be written, the file is not
changed. To reload by hand:

```sh
launchctl kill HUP gui/$UID/io.github.mblauberg.puremouse
```

## Defaults

One default set, defined once (`Config.defaultSetJSON` in PureMouseKit), is what PureMouse does with
no file, with `{}`, after Reset All Settings, and after a pane's Restore Defaults for that pane's
own keys. A file is laid over it, so a key left out means the default set's value, not "unchanged".

| Setting | Default |
|---|---|
| Smooth scrolling | On, Balanced (`speed` 1, `acceleration` 1, `smoothingMs` 125) |
| Wheel direction, wheel mode, SmartShift, DPI | Not set: the mouse keeps its own. Settings' wheel rows show it as a value (not reversed, the mouse's reported mode, SmartShift on) and always write the choice, SmartShift on as 12: the daemon leaves the mouse as it last set it, so a removed key would not undo anything. Only a mouse's choice equal to an explicit All Mice value removes its key |
| Wheel press (`middle`), top button | Mouse Default |
| `back`, `forward` | `navigateBack`, `navigateForward` |
| `gesture` | Click Mission Control, up Mission Control, down App Exposé, left and right Spaces |
| Thumb wheel | Scrolls sideways, not reversed |
| `universalControl.handOff` | On |

The set needs the Accessibility permission, since it posts scrolls and keystrokes. To turn a piece
off, say so in the file: `"smoothScroll": {"enabled": false}`, `"back": "default"` (the mouse's own
button) or `"gesture": "default"`. A gesture written in the file keeps the default directions it does
not name; set a direction to `"none"` to drop it, or give it a `hold` to replace them all.

PureMouse never rewrites an existing config to apply a new default set. A setting that the file leaves
out takes the default set's value, so upgrading can change what such a file does for the keys it omits
(smooth scrolling, Back and Forward, the gesture); keys the file sets are unchanged. Settings writes only
the keys you change, so Restore Defaults and Reset All Settings return keys to this set (Reset All also
saves the file as `config.json.bak`).

## Fields

| Field | Meaning |
|---|---|
| `dpi` | Sensor resolution, 50–25600. PureMouse uses the nearest value the mouse supports (200–8000 in steps of 50 on the MX Master 3S) and logs when it differs |
| `dpiPresets` | Up to 8 resolutions, each 50–25600, that the `cycleDPI` action steps through and the menu offers |
| `scrollWheel.inverted` | Invert the main wheel: in hardware, or in software with smooth scrolling on (a notched wheel has no hardware setting). With natural scrolling on, `true` gives classic wheel direction and leaves the trackpad alone |
| `scrollWheel.mode` | `"ratchet"` or `"freespin"` on first connect. Later toggles are kept. Requires SmartShift (0x2110 or Enhanced 0x2111); ratchet torque is left unchanged |
| `scrollWheel.smartShiftThreshold` | 1–50 enables SmartShift's automatic free-spin; 255 disables it. Must be 1–255. Requires 0x2110 or 0x2111 |
| `thumbWheel.inverted` | Invert the thumb wheel's scrolling: in hardware, or in software while PureMouse handles the wheel. Scrolling only: actions follow `reversed`. Global only |
| `thumbWheel.action`, `left`, `right`, `step`, `reversed` | What turning the thumb wheel does, and which way ([below](#thumb-wheel)) |
| `buttons` | Button → action or trigger table ([below](#buttons-actions-and-gestures)), including play-only haptics, or `"default"` for no binding: the mouse's own behaviour. `back`, `forward` and `gesture` are bound by the [default set](#defaults). The left and right buttons cannot be bound |
| `smoothScroll` | PureMouse scrolls both wheels itself unless `enabled` is false, when they scroll normally ([below](#smooth-scrolling)). On by default |
| `gesture.distanceMm` | How far the mouse moves before a gesture fires, in millimetres, 0.5–50. Default 4 |
| `gesture.repeatIntervalMs` | Minimum gap between repeated gestures in one hold, 0–5000. Default 400 |
| `holdMs` | How long a button is held before its `hold` fires, 150–1000 milliseconds. Default 350. Settings does not show it |
| `doubleClickMs` | How long a click waits for a second press where `doubleClick` is set, 150–1000 milliseconds. Default: the system's double-click interval (System Settings › Mouse), else 500. Settings does not show it |
| `notifications.lowBattery` | Default true. The menu bar app posts a macOS notification when a mouse's battery falls through 20% and again through 5% (level-only mice: when they report low and critical). A mouse that reconnects already below 20% warns once, if PureMouse can tell it is the same mouse as before (it reports its unit ID) and had not already warned at that level. The warning goes away when the mouse is charging or back at 25% or more, when the 5% warning replaces it, and when you switch this off. Works with the menu bar icon hidden (the menu bar app then runs without an icon); the daemon ignores it. Settings › General switches it; macOS asks for permission the first time |
| `apps` | Buttons, thumb wheel and smooth scrolling for particular apps ([below](#per-app-settings)) |
| `devices` | Settings for one model of mouse, over the ones above ([below](#per-device-settings)) |
| `universalControl.handOff` | While the pointer is on another Mac (Universal Control), hand the wheels and buttons back to macOS so they scroll and click there natively; take them again when the pointer returns. Default true; false keeps PureMouse's behaviour, which does nothing on the other Mac |

Settings › Mouse › Pointer › Edit Presets… edits the list in the selected mouse scope. Return or
leaving a field snaps it to a supported sensor step within 50–25600 (to a multiple of 50 when the
mouse reports no steps), merges duplicate speeds and sorts the list. The plus button adds the
current speed, or the next unsaved step above it (below it, from the top step), up to eight
entries, then focuses the new field. The minus button removes the focused row, otherwise the row
last edited, otherwise the checked speed. The checkmark button uses a saved speed.

A number outside its range is an error: the config is not loaded (on reload, the previous one stays
in effect) and the log names the field.

## Smooth scrolling

| Field | Default | Range | Meaning |
|---|---|---|---|
| `enabled` | true | | false scrolls natively but keeps the settings below |
| `speed` | 1 | 0.1–10 | Main wheel distance; 1 is about 40 px per notch when scrolling slowly |
| `horizontalSpeed` | 1 | 0.1–10 | Thumb wheel distance; 1 is about 360 px per turn when scrolling slowly |
| `acceleration` | 1 | 0–10 | Extra distance when scrolling fast (1.5× at 5 notches/s, 3× at 17, up to 8×); 0 is linear |
| `smoothingMs` | 125 | 0–2000 | How long the glide lasts. Most of each movement finishes within about 100 ms anyway, so longer values give a softer landing rather than lag. 0 scrolls immediately |
| `shiftScrollsHorizontally` | true | | Shift + wheel scrolls sideways |

`scrollWheel.inverted` and `thumbWheel.inverted` keep their meaning relative to the system's
natural-scrolling setting.

Smooth scrolling needs a wheel PureMouse can take over: a high-resolution wheel (HID++ 0x2121, and
0x2150 for a thumb wheel) or a notched one (0x2130, as on the Signature Plus M750 and the MX
Ergo). A notched wheel has no ratchet or direction setting in hardware, so `scrollWheel.inverted`
is applied by PureMouse and the ratchet settings do not apply. On a mouse with neither wheel
feature the wheel keeps scrolling natively and the log says so once.

## Thumb wheel

By default the thumb wheel scrolls sideways. `action` picks something else:

| `action` | Turning left / right | Default `step` |
|---|---|---|
| `"scroll"` | Scrolls sideways (the default) | |
| `"zoom"` | `zoomOut` / `zoomIn` (Cmd+- / Cmd+=) | 3 |
| `"volume"` | `volumeDown` / `volumeUp` | 2 |
| `"tabs"` | `previousTab` / `nextTab` (Ctrl+Shift+Tab / Ctrl+Tab) | 3 |
| `"spaces"` | `spaceLeft` / `spaceRight` | 4 |

Or give any two actions as `left` and `right`; with `action` too, each replaces that direction of
the pair (one left out stays as `action` has it, or does nothing). `step` is how far the wheel turns
per action, in its own steps, 1–36 (18 make a full turn on the MX Master 3S; default 3). Turning
faster gives several actions: media keys as fast as you turn (at most 4 for each report the mouse
sends), tab switching and other shortcuts at most one per 50 ms, zoom one per 40 ms, and Spaces,
Mission Control and the other animated actions one per 300 ms (turning in between is ignored).

```json
"thumbWheel": { "action": "volume" }
"thumbWheel": { "left": { "keys": "cmd+shift+[" }, "right": { "keys": "cmd+shift+]" }, "step": 4 }
```

Left and right are the directions that scroll left and right with natural scrolling off.
`"reversed": true` swaps which action each direction performs (default false); it applies to
actions only, as `inverted` applies to scrolling only, so either can be set without the other.
Natural scrolling does not affect actions.

```json
"thumbWheel": { "inverted": true, "action": "tabs", "reversed": true }
```

Thumb-wheel actions need the Accessibility permission, as smooth scrolling does. Choosing one takes
the thumb wheel over even without `smoothScroll`; where it still scrolls, it scrolls without
smoothing.

Settings › Mouse › Scrolling › Thumb Wheel sets `action`, or **Custom** for `left` and `right` (also shown
for a pair written by hand). Its Advanced… sheet has **Reverse direction** (`inverted`, while it
scrolls here or in some app), **Swap directions** (`reversed`, a switch) and **Turn distance** (`step`) while
the action in effect (the scope's own, else the wider scope's) is not scrolling, and **Speed** (`smoothScroll.horizontalSpeed`) while it scrolls. Custom's rows name
the way the wheel turns, so with `reversed` the **Turn left** row sets `right`. Scrolling's Restore
Defaults removes `smoothScroll`, `scrollWheel` and these thumb wheel keys, which leaves the
[default set](#defaults) (smooth scrolling on at Balanced); Buttons' removes `buttons` and `gesture`,
leaving the set's Back, Forward and gesture. Neither touches `apps`.

## Per-app settings

`apps` maps an app's bundle ID to the settings that differ in that app. Only `buttons`,
`thumbWheel` (`action`, `left`, `right`, `step` and `reversed`; not `inverted`) and `smoothScroll`
can differ; the rest write to the mouse and stay global. An app's `reversed` defaults to the global
one; Settings › Apps shows it as the **Swap directions** switch, which reads as Everywhere's until the app sets it
("Set for this app.", with a **Use Mouse Setting** link that removes the key).

```json
"apps": {
  "com.apple.Safari": { "buttons": { "gesture": { "left": "previousTab", "right": "nextTab" } } },
  "com.apple.Music": { "thumbWheel": { "action": "volume" } },
  "com.microsoft.Excel": { "smoothScroll": { "speed": 2, "smoothingMs": 0 } }
}
```

Each app entry changes only what it names, on top of the global settings: the buttons it lists,
a trigger table's triggers it lists (the others stay as the global table has them), and the
`thumbWheel` and `smoothScroll` keys it sets. A thumb wheel `left` or `right` alone keeps the other
direction and the step; an `action` keeps the step only if it is the global pair, else it brings its
own. Bundle IDs match regardless of case; one for an app
that is not installed is fine. `puremouse app` prints the bundle IDs PureMouse sees, or run
`osascript -e 'id of app "Safari"'`.

- A button press follows the frontmost app.
- Scrolling and the thumb wheel follow the app under the pointer, chosen when a scroll starts.

Settings › Apps lists the apps in `apps` and adds one from Applications or the running apps (it is
written only once a setting is chosen). For each app it sets the buttons, the thumb wheel and an own
scrolling `speed` and `smoothingMs` (both written when **Custom scrolling** is turned on, both
removed when it is turned off; each says "Set for this app." and can be given back alone); **Same as Mouse Settings** removes the app's key, and removing the
last one removes the app. Browsers, Zoom, Teams, Word, PowerPoint, Preview and Excel get a suggested
thumb wheel action. Keys it does not show, unknown ones included, stay as written.

An app may set a button to `"default"`: while that app is frontmost the button does what the mouse
does without PureMouse, even where the global settings bind it (see [Mouse Default](#buttons-actions-and-gestures)).

A button bound only in some apps is still taken over everywhere. Elsewhere the wheel press, back
and forward buttons click as usual; other controls do nothing. A button that is a gesture anywhere
holds the pointer still while pressed in every app. An app may turn on smooth scrolling that is off
globally, or the reverse; while any app scrolls smoothly, PureMouse scrolls everywhere, and where
smooth scrolling is off it scrolls without the glide at the given `speed`.

A per-app key that cannot be per-app (such as `dpi`) and an unknown button are skipped and
reported in the log; a bad value fails the load as anywhere else. Bundle IDs that differ only in
case name the same app: the log warns, and the entry last in sorted key order applies.

## Per-device settings

`devices` maps a device key to the settings that differ on that model of mouse. Everything else in
the file applies to every mouse.

```json
"dpi": 1600,
"devices": {
  "mb03400000000": { "name": "MX Master 3S", "dpi": 1200, "buttons": { "top": "launchpad" } },
  "pb02c": { "dpi": 1000 }
}
```

A device key is `m` plus the 12 hex digits of the model ID the mouse reports, or, for a mouse
that reports none, `p` plus the 4 hex digits of its product ID. The daemon logs each mouse's key
when it adopts it (`adopting MX Master 3S pid=0xb034 model=mb03400000000 ...`), and `status.json`
shows it as `model` ([companion.md](companion.md)). Keys are matched regardless of case. Two mice
of the same model share a key, and so share its settings. A model ID of all zeros or all `f` is
never a key.

An entry may set `dpi`, `dpiPresets`, `scrollWheel`, `thumbWheel` (`inverted` too), `smoothScroll`,
`buttons` and `gesture`, plus a `name` for your own reference, which PureMouse ignores. `apps`,
`universalControl` and `notifications` stay top level; in an entry they are skipped with a warning.

An entry changes only what it names, as an app entry does: the buttons it lists (a trigger table per
trigger), the `scrollWheel`, `thumbWheel`, `smoothScroll` and `gesture` keys it sets, and `dpi`;
`dpiPresets` replaces the whole list. Precedence is the top level, then `devices.<key>`, then
`apps.<bundle id>`: a mouse with an entry uses the entry over the top level, and the top-level
`apps` over that. An app that binds `forward` overrides the entry's `forward` in that app, while
the entry's `back` still applies there. An entry may set a button to `"default"` to leave it to the
mouse where the top level binds it (see [Mouse Default](#buttons-actions-and-gestures)).

What Settings writes under `devices` (`ConfigTree`, `ConfigScope.device`): only the keys a control sets
under the mouse's own entry, and only the sections above; `apps`, `universalControl` and
`notifications` are never written there. An entry is found the way the decoder finds it, so a file
that spells the key in other case (`MB03400000000`) is edited in place and gets no lowercase twin;
with several spellings, the last in sorted order is the one edited. The first value for a mouse
creates its entry with a `name` (the mouse's name, else its key), written once. Putting a control
back to "All Mice" removes its key there (Mouse Default is a value, not a removal: it writes
`"default"` under the mouse's entry, and under All Mice it removes the key, or writes `"default"` where
the default set binds the button, Back for example, so the set does not return; for a gesture direction, its key in the gesture, and the
whole binding with the last direction), and removing the last override removes the entry, so an entry
with only a `name` is not kept (keys Settings does not know are kept, and keep the entry and its
`name`). "Do Nothing" is a value, not a removal: on a mouse it hides the top level's action. A
mouse's `smoothScroll` goes with its last key, as it means the same left out. Only per-device sections are
written: a section the decoder would skip is refused, though inside a section a key is written
as given. A JSON `null` in an entry or at the top level reads as absent, as the decoder reads it.

### Settings and per-mouse values

Mouse shows a pop-up, All Mice then each known mouse, when two or more mice are known or the config
has any `devices` entry (so a lone mouse that has an entry gets it too: the entry's values would
otherwise shadow edits made for All Mice with nothing to show it). Known mice are the daemon's
devices that have a key, one per key, then each `devices` entry no connected mouse has, named from
its `name`, else "Unknown mouse <key>". The last choice is remembered for the user, and All Mice is
the default; a remembered mouse that is no longer listed is All Mice.

Each Mouse pane reads the value in effect (`resolved`) and writes in the chosen scope. A control the
mouse has no value for looks exactly as it does under All Mice, with no mark; one it sets says "Set for
this mouse." with a "Use All Mice Setting" link that removes it (`InheritedValue`, the same presentation
an app uses with "Set for this app." and "Use Mouse Setting"). A pop-up's first entry is "Same as All
Mice (value)". Every control of a row, including a switch, a segmented control and a slider, is the one
All Mice shows while the mouse leaves the value alone; VoiceOver reads it with its source ("On, same as
All Mice"). The thumb wheel's rows follow the action in effect: a mouse that leaves Custom to All Mice shows
Turn left and Turn right, and a mouse can set the turn distance or either direction alone, which then
carries the "Set for this mouse." line. A gesture direction the mouse sets itself is marked the same way,
whether or not All Mice has a gesture. A section's Restore Defaults removes that mouse's
keys for the section, never its `name`. The Presets row of a mouse that uses All Mice's presets reads
as All Mice's does (the list), and a mouse's own empty `dpiPresets: []` is kept, as it means
no presets for that mouse. Giving back the mouse's Smooth scrolling removes the mouse's
`enabled`, and its whole `smoothScroll` once no other key is left in it. A mouse's rows are hidden by what it reports: a capability
reported `false` hides its rows, an omitted one is unknown and shows them, and a value the mouse itself
sets keeps its row with "Not supported by this mouse." (a value only All Mice sets does not). For All Mice a section shows if
any known mouse has the feature; while a mouse is not connected, or a `devices` entry names a mouse the
daemon does not report, nothing is hidden, since that mouse may have it. With several spellings of one
key (`MB…` and `mb…`) the last in sorted order is the entry, and giving back its last override leaves
a name-only entry in its place, so the other spelling does not apply in its stead (Kit replaces an
earlier entry whole). Reset All Settings, in General, resets every mouse and every app, not only the
chosen mouse. Apps are the same for every mouse, so the Apps tab has no pop-up.

A mouse that reports no 0x0003 identity is keyed by its product ID, which can differ between
receivers and Bluetooth (`pb02c` over Bluetooth, an `m…` key over Bolt when the model ID is read).
Settings treats them as two mice and does not alias them; copy the entry to share settings.

A key that is neither form (a typo, or a mouse's name) matches no mouse: the log warns and the entry
is skipped, though a bad value in it still fails the load. Keys that differ only in case warn, and
the last one applies. A cycled DPI (`cycleDPI`) is kept on reload unless that mouse's own `dpi` or
`dpiPresets` changed.

## Buttons, actions and gestures

**Buttons:** `gesture` (thumb), `back`, `forward`, `top` (behind the wheel), `middle` (wheel
press), `thumbPanel` (MX Master 4 haptic/Actions Ring panel, 0x01A0), or any hex control ID such
as `"0x00c4"`. Names apply only when the mouse has that control. **Find by Pressing…** in Settings › Mouse › Buttons, or
`puremouse probe`, finds a control's ID. The shared library also holds a table of display names for
common mouse controls, apart from these config names (for example 0x00fd is the "DPI button");
the log and the menu adopt it in later changes. Any control works by its hex ID whether or not it
has a name. A binding the mouse lacks, or cannot hand to PureMouse, is skipped for that mouse
(noted once in the log at debug level), so one config can serve mice with different buttons; a
`devices` entry binds a control for one model only.

The left and right buttons (0x0050 and 0x0051) cannot be bound, globally or per app. Their
bindings are ignored with a warning; **Find by Pressing…** always leaves them clicking normally.

**Mouse Default:** the string `"default"` in any `buttons` section (top level, `devices.<key>.buttons`,
`apps.<id>.buttons`) means no binding: the button works as the mouse does without PureMouse. It is
not an action, so it is not accepted where an action is (a gesture direction, the thumb wheel's
`left` and `right`). On a mouse's entry it removes the top level's binding for that control, under
whichever name spells it, so the mouse behaves as it does without PureMouse there while other mice
keep the binding; in an app it does the same while that app is frontmost. The control is still taken
over, and the daemon performs what the mouse itself would, from one table (`Config.nativeBehaviour(of:)`):
the wheel click, back and forward post their ordinary click (0x52, 0x53, 0x56), the top button
(0xC4) switches the wheel mode as `toggleScrollMode` does, and the DPI button (0xFD) cycles the pointer speed
as `cycleDPI` does. Any other control (the gesture button, the thumb panel, a control Kit has no
name for) has no behaviour of its own to hand back, so it does nothing, and Settings does not offer
Mouse Default for it on a mouse or in an app. While a control is a gesture in some scope it is held
with its pointer movement diverted; pressed where it resolves to something that is not a gesture,
the pointer is freed for that press and diverted again on release. At the top level
there is nothing to hide, so `"default"` is the same as leaving the button out. Within one section, if
two names spell one control, the last in sorted order decides, as for any two bindings, and a
`"default"` that wins removes every earlier name for the control. Settings reads and writes a mouse's
or an app's button the same way: the last spelling is the one shown and edited, and giving the button
back to the wider scope removes every spelling. The left and
right buttons and an unknown button name keep their warnings. Settings writes it from a mouse's or an
app's action picker (**Mouse Default**), beside **Same as All Mice** / **Same as Mouse Settings**, which
removes the key instead. Where the wider scope already is Mouse Default, the picker lists only
**Same as …**, since the two would be the same. Choosing **Hold and Move** on a mouse or in an app that
has Mouse Default, when the wider binding is a gesture, removes the key, so the mouse takes that
gesture whole (its click and directions), as **Same as …** does. Choosing **Hold and Move** when
no direction is set in the target scope seeds Mission Control up, App Exposé down and Spaces left
and right. Existing directions are kept.

**Actions:** `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`, `spaceRight`,
`navigateBack`, `navigateForward`, `toggleScrollMode`, `cycleDPI`, `playPause`, `nextTrack`,
`previousTrack`, `volumeUp`, `volumeDown`, `mute`, `middleClick`, `brightnessUp`, `brightnessDown`,
`nextTab`, `previousTab`, `zoomIn`, `zoomOut`, `precisePointer`, `dragLock`, `none`,
`{"keys": "cmd+shift+4"}`, `{"run": "open -a Safari"}`, `{"haptic": "sharpStateChange"}`,
`{"precisePointer": 400}`.

`run` starts the command with `/bin/sh -c`, as you, and does not wait for it. Its output is
discarded; a command that exits non-zero is logged once with its first 80 characters and its exit
status. To see what a command prints, redirect it to a file:
`{"run": "my-script >> /tmp/my-script.log 2>&1"}`.

`spaceLeft` and `spaceRight` send your own "Move left/right a space" shortcuts from System
Settings › Keyboard › Keyboard Shortcuts › Mission Control, or Ctrl+Left/Right if those are off.
`nextTab`/`previousTab` send Ctrl+Tab and Ctrl+Shift+Tab, and `zoomIn`/`zoomOut` Cmd+= and Cmd+-,
which most apps share; use `{"keys": ...}` for an app that differs.

`middleClick` holds the middle button down while its control is held, so a press can drag
(middle-drag, autoscroll): as a bare action, as a table's `click` with no `doubleClick` or `hold`,
and as a `hold`. Where the click fires on release, after a double-click or as a Hold and Move direction,
it is one full click.

`precisePointer` slows the pointer while its button is held: to half the current resolution, or to
the resolution given (`{"precisePointer": 400}`, 50–25600), each snapped to a step the mouse supports.
Only the live resolution changes, which the mouse does not keep. On release the pointer returns to
whatever its speed is by then, so a `cycleDPI` during the hold is not undone. `dragLock` holds the
left button down at one click and lets go at the next, so a drag needs no held button. Both end on
release (Precise Pointer) or are let go (Drag Lock) when the mouse disconnects, the config reloads,
PureMouse pauses or quits, or Universal Control takes the pointer.

`cycleDPI` switches to the next of `dpiPresets` above the current resolution, wrapping to the
lowest. The choice survives reconnects until a config change alters `dpi` or `dpiPresets`.

**Haptics (MX Master 4):** choose an effect under Haptic Feedback in a button's action picker, or
set one in JSON, for example `"thumbPanel": {"haptic": "sharpStateChange"}`. It plays only if the mouse reports the haptic
feature and supports that waveform; otherwise it is ignored with a log message once per session.
An absent haptic feature is cached for the session, so repeated presses do not query the mouse again.
It does not change strength, enable haptics or write any haptic configuration. If haptics are
disabled on the mouse, playing an effect may produce no feedback.

| Action field | Values | Source / waveform IDs |
|---|---|---|
| `haptic` | `sharpStateChange`, `dampStateChange`, `sharpCollision`, `dampCollision`, `subtleCollision`, `happyAlert`, `angryAlert`, `completed`, `square`, `wave`, `firework`, `mad`, `knock`, `jingle`, `ringing`, `whisperCollision` | Solaar: 0–14 in order, plus `whisperCollision` at 0x1B |
| `haptic` | `simpleBreathing`, `boxBreathing`, `bellyBreathing`, `timer`, `startEndBreathingSignal` | Logi Options+: 15–19 in order |

The action picker lists them under Haptic Feedback (MX Master 4), in words (“Happy Alert”), and a
bound button reads “Haptic: Happy Alert”. Settings shows the Thumb panel row only when a connected
mouse has it or the config binds it.
Haptic actions also work for gesture directions. Automatic feedback on DPI changes is not
implemented.

**Triggers ([ADR 0024](adr/0024-one-action-model.md)):** a button's value is an action, or a table of
what each way of pressing it does:

```json
"buttons": {
  "forward": { "click": "navigateForward", "doubleClick": "missionControl", "hold": "precisePointer" },
  "gesture": { "click": "missionControl", "up": "missionControl", "down": "appExpose" },
  "top": "dragLock"
}
```

| Key | Fires |
|---|---|
| `click` | A press and release. A bare action (`"back": "navigateBack"`) is the same as `{"click": …}` |
| `doubleClick` | A second press within the double-click interval (`doubleClickMs`) |
| `hold` | Once the button has been held `holdMs`; the click is then not sent |
| `up`, `down`, `left`, `right` | **Hold and Move:** holding the button and moving the mouse that way (`gesture.distanceMm`). While the button is held the pointer stays still; released without moving, it clicks |

What a table costs is only the wait it asks for. With only a click bound, the press fires
immediately, as before. With `hold`, the click fires on release instead of on press. With
`doubleClick`, a single click fires once the interval has passed without a second press. A table
that names no `click` (here, or in the wider table it is laid over) leaves the click to the mouse, as
Mouse Default does: a quick tap posts the button's ordinary click, press and release together (the
wheel click, back and forward), the top and DPI buttons do what they do without PureMouse, and a
control with no behaviour of its own does nothing. `"click": "none"` names a click: the button does
nothing. Hold and Move's
directions take the place of `hold`: a table may have one or the other, and having both is an
error at `hold`. The `scroll` key is reserved for Hold and Scroll and is an error until it ships; any
other unknown key is an error at that key. `precisePointer` lasts while the button is held, so it is
accepted only as `click` or `hold` (an error elsewhere, including the thumb wheel). As the click it
starts at the press and owns the button, so Settings does not combine it with `doubleClick` or
`hold`; as the hold it starts after the hold delay, and a quick click still clicks.

A table in a mouse's or an app's `buttons` changes only the triggers it names; the others come from
the wider scope's table (the top level for a mouse, the mouse or top level for an app). Set one to
`"none"` to switch it off there. Writing one hold form drops the other from the wider table, so a
`hold` replaces inherited directions and a direction replaces an inherited `hold`. A bare action
replaces the whole table, and a table over a wider bare action starts with no triggers. Settings
writes a table back to a bare action once its click is all that is left. Adding Double-click or
Hold to a button whose click is Mouse Default writes a table with no `click`, so a quick tap stays the
mouse's own; Settings writes `"click": "none"` only when the person chooses **Do Nothing** for the
click. Choosing **Mouse Default** for the click of a table takes its `click` key out, and a table
left with no click and no trigger is written as no entry (the bare default), or as `"default"` where
a wider bare action or the default set's binding would otherwise apply.

## System Settings

- **Natural scrolling** applies as usual; PureMouse reads it at the start of each scroll.
- **Scrolling speed** no longer affects the mouse once smooth scrolling is on; use `speed` and
  `acceleration` instead. Other mice are unaffected.
- **Tracking speed** and pointer acceleration still apply on top of `dpi`.
- **Swipe between pages**, Mission Control and the "Move left/right a space" keyboard shortcuts
  must stay enabled for the back/forward and Spaces actions.

# Configuration

Settings and hand edits share one file, `~/.config/puremouse/config.json`. Every field is optional;
anything left out keeps the mouse's existing setting. A short example
([`config.example.json`](../config.example.json) has more):

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
only the keys it shows and keeps any others. To reload by hand:

```sh
launchctl kill HUP gui/$UID/io.github.mblauberg.puremouse
```

## Fields

| Field | Meaning |
|---|---|
| `dpi` | Sensor resolution, 50–25600. PureMouse uses the nearest value the mouse supports (200–8000 in steps of 50 on the MX Master 3S) and logs when it differs |
| `dpiPresets` | Up to 8 resolutions, each 50–25600, that the `cycleDPI` action steps through and the menu offers |
| `scrollWheel.inverted` | Invert the main wheel in hardware. With natural scrolling on, `true` gives classic wheel direction and leaves the trackpad alone |
| `scrollWheel.mode` | `"ratchet"` or `"freespin"` on first connect. Later toggles are kept. Requires SmartShift (0x2110 or Enhanced 0x2111); ratchet torque is left unchanged |
| `scrollWheel.smartShiftThreshold` | 1–50 enables SmartShift's automatic free-spin; 255 disables it. Must be 1–255. Requires 0x2110 or 0x2111 |
| `thumbWheel.inverted` | Invert the thumb wheel: in hardware, or in software while PureMouse handles the wheel |
| `thumbWheel.action`, `left`, `right`, `step` | What turning the thumb wheel does ([below](#thumb-wheel)) |
| `buttons` | Button → action or gesture, including play-only haptics ([below](#buttons-actions-and-gestures)) |
| `smoothScroll` | If present, PureMouse scrolls both wheels itself ([below](#smooth-scrolling)). If absent, or `enabled` is false, the wheels scroll normally |
| `gesture.distanceMm` | How far the mouse moves before a gesture fires, in millimetres, 0.5–50. Default 4 |
| `gesture.repeatIntervalMs` | Minimum gap between repeated gestures in one hold, 0–5000. Default 400 |
| `notifications.lowBattery` | Default true. The menu bar app posts a macOS notification when a mouse's battery falls through 20% and again through 5% (level-only mice: when they report low and critical). Needs the menu bar icon shown; the daemon ignores it. Settings › General switches it; macOS asks for permission the first time |
| `apps` | Buttons, thumb wheel and smooth scrolling for particular apps ([below](#per-app-settings)) |

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
faster gives several actions: media keys as fast as you turn, tab switching and other shortcuts at
most one per 50 ms, zoom one per 40 ms, and Spaces, Mission Control and the other animated actions
one per 300 ms (turning in between is ignored).

```json
"thumbWheel": { "action": "volume" }
"thumbWheel": { "left": { "keys": "cmd+shift+[" }, "right": { "keys": "cmd+shift+]" }, "step": 4 }
```

Left and right are the directions that scroll left and right with natural scrolling off;
`inverted` swaps them. Natural scrolling does not affect actions.

Thumb-wheel actions need the Accessibility permission, as smooth scrolling does. Choosing one takes
the thumb wheel over even without `smoothScroll`; where it still scrolls, it scrolls without
smoothing.

## Per-app settings

`apps` maps an app's bundle ID to the settings that differ in that app. Only `buttons`,
`thumbWheel` (not `inverted`) and `smoothScroll` can differ; the rest write to the mouse and stay
global.

```json
"apps": {
  "com.apple.Safari": { "buttons": { "gesture": { "left": "previousTab", "right": "nextTab" } } },
  "com.apple.Music": { "thumbWheel": { "action": "volume" } },
  "com.microsoft.Excel": { "smoothScroll": { "speed": 2, "smoothingMs": 0 } }
}
```

Each app entry changes only what it names, on top of the global settings: the buttons it lists,
a gesture's directions it lists (the others stay as the global gesture has them), and the
`thumbWheel` and `smoothScroll` keys it sets. A thumb wheel `left` or `right` alone keeps the other
direction and the step; an `action` keeps the step only if it is the global pair, else it brings its
own. Bundle IDs match regardless of case; one for an app
that is not installed is fine. `puremouse app` prints the bundle IDs PureMouse sees, or run
`osascript -e 'id of app "Safari"'`.

- A button press follows the frontmost app.
- Scrolling and the thumb wheel follow the app under the pointer, chosen when a scroll starts.

A button bound only in some apps is still taken over everywhere. Elsewhere the wheel press, back
and forward buttons click as usual; other controls do nothing. A button that is a gesture anywhere
holds the pointer still while pressed in every app. An app may turn on smooth scrolling that is off
globally, or the reverse; while any app scrolls smoothly, PureMouse scrolls everywhere, and where
smooth scrolling is off it scrolls without the glide at the given `speed`.

A per-app key that cannot be per-app (such as `dpi`), an unknown button and a repeated bundle ID
are skipped and reported in the log; a bad value fails the load as anywhere else.

## Buttons, actions and gestures

**Buttons:** `gesture` (thumb), `back`, `forward`, `top` (behind the wheel), `middle` (wheel
press), `thumbPanel` (MX Master 4 haptic/Actions Ring panel, 0x01A0), or any hex control ID such
as `"0x00c4"`. Names apply only when the mouse has that control. **Select by Pressing** in Settings › Buttons, or
`puremouse probe`, finds a control's ID.

**Actions:** `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`, `spaceRight`,
`navigateBack`, `navigateForward`, `toggleScrollMode`, `cycleDPI`, `volumeUp`, `volumeDown`, `mute`,
`brightnessUp`, `brightnessDown`, `nextTab`, `previousTab`, `zoomIn`, `zoomOut`, `none`,
`{"keys": "cmd+shift+4"}`, `{"run": "open -a Safari"}`, `{"haptic": "sharpStateChange"}`.

`spaceLeft` and `spaceRight` send your own "Move left/right a space" shortcuts from System
Settings › Keyboard › Keyboard Shortcuts › Mission Control, or Ctrl+Left/Right if those are off.
`nextTab`/`previousTab` send Ctrl+Tab and Ctrl+Shift+Tab, and `zoomIn`/`zoomOut` Cmd+= and Cmd+-,
which most apps share; use `{"keys": ...}` for an app that differs.

`cycleDPI` switches to the next of `dpiPresets` above the current resolution, wrapping to the
lowest. The choice survives reconnects until a config change alters `dpi` or `dpiPresets`.

**Haptics (MX Master 4, untested):** configure an action in JSON, for example
`"thumbPanel": {"haptic": "sharpStateChange"}`. It plays only if the mouse reports the haptic
feature and supports that waveform; otherwise it is ignored with a log message once per session.
An absent haptic feature is cached for the session, so repeated presses do not query the mouse again.
It does not change strength, enable haptics or write any haptic configuration. If haptics are
disabled on the mouse, playing an effect may produce no feedback.

| Action field | Values | Source / waveform IDs |
|---|---|---|
| `haptic` | `sharpStateChange`, `dampStateChange`, `sharpCollision`, `dampCollision`, `subtleCollision`, `happyAlert`, `angryAlert`, `completed`, `square`, `wave`, `firework`, `mad`, `knock`, `jingle`, `ringing`, `whisperCollision` | Solaar: 0–14 in order, plus `whisperCollision` at 0x1B |
| `haptic` | `simpleBreathing`, `boxBreathing`, `bellyBreathing`, `timer`, `startEndBreathingSignal` | Logi Options+: 15–19 in order |

Settings displays existing bindings as “Haptic: &lt;name&gt;”; choose haptic waveforms in JSON.
Haptic actions also work for gesture directions. Automatic feedback on DPI changes is not
implemented.

**Gestures:** an object with any of `click`, `up`, `down`, `left` and `right`, each an action.
While a gesture button is held, the pointer stays still.

## System Settings

- **Natural scrolling** applies as usual; PureMouse reads it at the start of each scroll.
- **Scrolling speed** no longer affects the mouse once smooth scrolling is on; use `speed` and
  `acceleration` instead. Other mice are unaffected.
- **Tracking speed** and pointer acceleration still apply on top of `dpi`.
- **Swipe between pages**, Mission Control and the "Move left/right a space" keyboard shortcuts
  must stay enabled for the back/forward and Spaces actions.

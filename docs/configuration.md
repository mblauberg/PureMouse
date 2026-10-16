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
| `scrollWheel.mode` | `"ratchet"` or `"freespin"` on first connect. Later toggles are kept |
| `scrollWheel.smartShiftThreshold` | 1–50 enables SmartShift's automatic free-spin; 255 disables it. Must be 1–255 |
| `thumbWheel.inverted` | Invert the thumb wheel in hardware |
| `buttons` | Button → action or gesture ([below](#buttons-actions-and-gestures)) |
| `smoothScroll` | If present, PureMouse scrolls both wheels itself ([below](#smooth-scrolling)). If absent, or `enabled` is false, the wheels scroll normally |
| `gesture.distanceMm` | How far the mouse moves before a gesture fires, in millimetres, 0.5–50. Default 4 |
| `gesture.repeatIntervalMs` | Minimum gap between repeated gestures in one hold, 0–5000. Default 400 |
| `notifications.lowBattery` | Default true. The menu bar app posts a macOS notification when a mouse's battery falls through 20% and again through 5% (level-only mice: when they report low and critical). Needs the menu bar icon shown; the daemon ignores it. Settings › General switches it; macOS asks for permission the first time |

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

## Buttons, actions and gestures

**Buttons:** `gesture` (thumb), `back`, `forward`, `top` (behind the wheel), `middle` (wheel
press), or any hex control ID such as `"0x00c4"`. **Select by Pressing** in Settings › Buttons, or
`puremouse probe`, finds a control's ID.

**Actions:** `missionControl`, `appExpose`, `showDesktop`, `launchpad`, `spaceLeft`, `spaceRight`,
`navigateBack`, `navigateForward`, `toggleScrollMode`, `cycleDPI`, `none`, `{"keys": "cmd+shift+4"}`,
`{"run": "open -a Safari"}`.

`cycleDPI` switches to the next of `dpiPresets` above the current resolution, wrapping to the
lowest. The choice survives reconnects until a config change alters `dpi` or `dpiPresets`.

**Gestures:** an object with any of `click`, `up`, `down`, `left` and `right`, each an action.
While a gesture button is held, the pointer stays still.

## System Settings

- **Natural scrolling** applies as usual; PureMouse reads it at the start of each scroll.
- **Scrolling speed** no longer affects the mouse once smooth scrolling is on; use `speed` and
  `acceleration` instead. Other mice are unaffected.
- **Tracking speed** and pointer acceleration still apply on top of `dpi`.
- **Swipe between pages**, Mission Control and the "Move left/right a space" keyboard shortcuts
  must stay enabled for the back/forward and Spaces actions.

# UI design

How PureMouse's menu and Settings look and behave. Words are in `docs/ui-language.md`. A change
to the UI follows this page, and a change to this page lands with the UI it changes.

## Principles

PureMouse should feel like part of macOS 26 and 27: simple and clear for everyone by default, with
every advanced option one step away for the people who want it. Calm and minimal, never
overwhelming, and no feature is dropped to get there.

- **System Settings is the model.** Every pane is a `Form` with `.formStyle(.grouped)`, made of
  `LabeledContent` rows: a sentence-case title over a one-line caption that someone who has never
  used a mouse utility understands.
- **System controls first.** Switch, menu pop-up, segmented control (four segments or fewer, fixed
  count), slider with end labels, stepper, `ContentUnavailableView`. A custom view carries a
  comment naming the system control that could not do the job.
- **Let the system draw the chrome.** No explicit font sizes, control widths or heights, corner
  radii, materials, `glassEffect`, backgrounds or colour literals, and no `.controlSize`
  overrides. Use semantic text styles and colours. Show state as a symbol plus a word, never
  colour alone; colour goes on the symbol (`.multicolor`), words stay `.secondary`. These are
  scan-tested (`.system(size:`, numeric `.frame(width:`/`height:` on controls, `Color.<name>`,
  `.white`, `.black` outside symbol rendering).
- **Simple by default.** Each default view fits within 600 pt of content height at the 600 pt
  window width, in light and dark, with one-mouse and two-mouse fixtures. A fresh install shows no
  advanced content.
- **One disclosure mechanism per level.**
  - The pane footer's **Advanced…** button opens a sheet, next to Restore Defaults.
  - A **disclosure** only for a control's own children (gesture directions, Exact value).
  - **⌥ alternates** only in the status menu.
  - No sheet opens from a sheet; inside a sheet, use disclosures.
  - Every advanced control has a safe default that the pane's Restore Defaults covers.
- **Hide or dim.** Dim a row only when a switch above turns its feature off. Hide rows that do not
  apply to the current mode or mouse.
- **Focus and access.** Windows, panes, sheets and popovers open with nothing focused. Every
  control is reachable by Tab and has a distinct accessibility label.
- **Captures** and README screenshots come only from builds that record the macOS 26 SDK or later
  (`scripts/verify-bundle.sh` checks it).

## Layout

| Place | Shown by default | Advanced |
|---|---|---|
| General | Status (PureMouse running/paused/off, Start or Stop, active notices), Open at login, Show in menu bar, Low battery notification, Permissions | Advanced… sheet: Work with Universal Control, Config file, Log, Reset All Settings… |
| Mouse header | Buttons, Scrolling, Pointer segments; mouse pop-up with two or more mice; Find by Pressing and the device card on Buttons | — |
| Mouse › Buttons | One row per button with its action | Gesture directions (disclosure, collapsed, caption summarises them); Other controls (disclosure); Advanced… sheet: gesture distance and repeat |
| Mouse › Scrolling | Smooth scrolling, Feel, Speed; Reverse direction, Wheel mode, SmartShift (when the mouse has them); thumb wheel Action (Turn left/right when Custom) | Advanced… sheet: acceleration, glide, Shift for sideways; SmartShift threshold; thumb wheel reverse, turn distance, speed |
| Mouse › Pointer | Pointer Speed slider with its value; Presets summary row | Exact value (disclosure); Edit Presets… sheet (also opened from the menu) |
| Apps | App list with summaries, Add App in the footer, routing note | Each app opens in a sheet; inside it, gesture directions, other controls and more thumb wheel options are disclosures |
| About | Icon, name, version, Check for Updates, links, footnote | — |
| Status menu | Device header, attention rows when active, Smooth Scrolling, Pointer Speed, Start/Pause/Resume, Settings…, Quit PureMouse | ⌥: detail line, Reload Config, Show Log in Finder, Hide Menu Bar Icon |

Menu symbols: within a group, all items have a symbol or none do.

# UI design

How PureMouse's menu and Settings look and behave. Words are in `docs/ui-language.md`. A change
to the UI follows this page, and a change to this page lands with the UI it changes. Rules come
from Apple's Human Interface Guidelines (HIG, revised June 2026) and macOS 27 unless marked
**house rule**; the sources are listed at the end.

## Principles

PureMouse should feel like part of macOS 27: simple and clear for everyone by default, with every
advanced option one step away for the people who want it. Calm and minimal, never overwhelming,
and no feature is dropped to get there. "Simple" is not "minimal": a setting earns its place by
answering a question people have, and a good default means most people never touch it.

- **Defaults do the work.** Ship the setting that suits most people, keep the number of settings
  small, and add one only when a default cannot serve both camps.
- **System controls, system chrome.** Standard controls in a grouped `Form` pick up Liquid Glass,
  macOS 27's sizes and every accessibility setting for free. A custom view carries a comment
  naming the system control that could not do the job.
- **One idea per row.** A row is a sentence-case title over at most one line of caption that
  someone who has never used a mouse utility understands.
- **Live, in place.** A change applies the moment it is made and shows its effect where it was
  made. No Save button, no "Saved" confirmation, no alert for information.
- **Never duplicate System Settings silently.** Where a control overlaps one in System Settings
  (scroll direction, pointer speed), its caption says it applies to this mouse; where the system
  owns the setting, link to it with a button instead of copying it.

## Settings window

- Opened by Settings… (⌘,) in the app menu and the status menu, never from a toolbar button.
- A non-customisable toolbar of tabs, General, Mouse, Apps and About, that always shows the active
  tab. The window title is the tab's name. Minimise and zoom are dimmed; the window has no resize
  handle and sizes to the pane, never taller than the screen.
- It reopens on the last tab and segment (`SettingsSelection`) and remembers its position.
- Mouse's header strip has a leading slot for the mouse pop-up (`MousePopUp`: All Mice, then each
  known mouse), shown with two or more mice known or any `devices` entry. Its closed text is the
  mouse's name, truncated at the tail by the width the strip leaves it (one line, never over the
  centred segments). The Apps note ("Apps are the same for every mouse.") is the
  pop-up's last menu item, a tooltip and its accessibility hint rather than a line under it: a line
  costs 15 pt in a strip every segment shares, and Scrolling has 6 pt to spare. "Settings you don't
  change follow All Mice." is the menu's other note, said once. A pane under a chosen mouse
  (and an app's sheet) marks changes, not inheritance (`InheritedValue`): a row that inherits looks
  exactly as it does under All Mice, with the same control, full contrast and its usual help caption;
  a row with its own value adds the line "Set for this mouse." ("Set for this app.") and an inline
  link, "Use All Mice Setting" ("Use Everywhere Setting"), moves its help to the tooltip, and offers
  the same command in its context menu and as a VoiceOver action. No row reserves a hidden slot, so
  every trailing control ends at the form's trailing edge and a slider track never moves between
  scopes. A mouse's pane is never taller than the same pane under All Mice, except by that one line
  on changed rows.
- ⌘W closes it, and closing it quits the helper. Esc dismisses a sheet; Return takes the sheet's
  default button.
- Nothing is placed behind the toolbar or the tab bar: no backgrounds, materials or
  `NSVisualEffectView`. The scroll edge effect stays automatic.

## Forms and controls

- Every pane is a `Form` with `.formStyle(.grouped)` of `LabeledContent` rows. Section headers are
  Title Case (`docs/ui-language.md`); grouped forms no longer upper-case them.
- Controls, in order of preference: switch, pop-up menu, segmented control (four segments or
  fewer, a fixed count, all text or all symbols), slider (minimum leading, end labels, live value),
  stepper, `ContentUnavailableView`. A pop-up's **Custom** entry may reveal the rows it needs.
- **One pop-up look.** Every pop-up (an action row on Buttons, the thumb wheel's Action, an app's
  "Same as Everywhere" rows) is drawn the same way (`PopUpLabel`): the value, then the up/down
  chevrons. A value left to the mouse (Mouse Default) is an ordinary enabled choice in primary
  text, and so is a value inherited from a wider scope: nothing is dimmed to say so. An empty state's next step is a
  bordered push button (Add App…), as in System Settings: a grouped form draws a pull-down in a
  row borderless.
- **Let the system draw.** No explicit font sizes, control widths or heights, literal corner radii,
  materials, `glassEffect`, `.buttonStyle(.glass)`, backgrounds or colour literals. No
  `.controlSize` overrides except `.mini` on a switch, if a grouped form's default ever renders
  larger than System Settings' (check it in a capture), and never `.extraLarge`. Text is a
  semantic style (`.title3`, `.body`, `.callout`, `.subheadline`) and a symbol is sized with
  `.imageScale`. A slider's end words sit under its ends in caption type, as System Settings
  draws them, hidden from VoiceOver (the slider speaks its value), and every slider is one width
  so a pane's tracks line up (`ValueSlider`). A shortcut recorder is a `.bordered`
  button with the shortcut in `.title3` and the recording state as a symbol and a word (no system
  control records a ⌘ chord). Scan-tested by `UIChromeScanTests`, which reads
  `Sources/PureMouseSettingsUI` and fails on `.system(size:`, a `.frame` with a numeric size,
  `.controlSize` other than `.mini` on a switch, `.background(` or `.background {`, `Material`,
  `NSVisualEffectView`, `glassEffect`, `.buttonStyle(.glass`, `cornerRadius`, `RoundedRectangle(`,
  `Color.<name>` other than `clear`, `primary` and `secondary`, a colour built from values
  (`Color(red:`, `Color(hue:`; a semantic `NSColor` is the system's), `.custom(` fonts, and named colours (`.white`, `.black`, `.red`
  and the rest). A size or colour held in a constant is not caught: name it in review, not
  around the scan. Its allow-list holds at most five lines, each a file, a source
  fragment and a reason, and an entry that no longer matches fails: today the About icon's
  artwork frame, the action picker popover's size (a `List` has none of its own), the slider's
  width and its readout's minimum width, and the shortcut and command editors' width (also
  popovers inside an app's sheet, so narrower than it). Other sheets share one width
  (`SettingsWindowController.sheetWidth`) and take their height from their content.
- **Custom shapes are concentric.** Prefer a system container (form section, `GroupBox`). A custom
  rounded view, such as the device card, uses `ConcentricRectangle` (macOS 26+) so it follows the
  window's radius; the macOS 14–15 branch may use one named radius constant.
- **Colour.** Semantic system colours only. State is a symbol plus a word, never colour alone.
  Tint goes on one control at most (the pane's primary action, if any). Symbols: hierarchical by
  default, `.multicolor` only where the colour means something (a warning, a battery level),
  variable colour only for a changing value (battery).
- **Typography.** Text styles only; macOS has no Dynamic Type, so nothing smaller than `.caption`.

## Disclosure

Each level has one mechanism, and each label says what it reveals.

- **Advanced…** A push button at the trailing edge of the pane's last row (`PaneFooter`, in the
  last section's footer, so it scrolls with the form; nothing is pinned to the window's bottom
  edge). Restore Defaults sits at the leading edge of the same row. Either is optional.
- **Advanced sheet** (`AdvancedSheet`): a title, a grouped form and one **Done** button. Its
  settings apply live, like the pane's, so there is nothing for Cancel to undo (house rule: System
  Settings › Mouse › Advanced… does the same; the HIG pairs Done with Cancel for sheets that hold
  edits). A sheet that holds edits until confirmed, such as the shortcut recorder, has Cancel and a
  verb. Each sheet has a fixed width and fits its content.
- **Disclosure triangle** only for a control's own children (gesture directions, Exact value);
  at most one per row.
- **⌥ alternates** only in the status menu, and each also has a home in Settings (see Status menu).
- No sheet opens from a sheet; inside a sheet, use disclosures, and an editor that is a sheet
  elsewhere (keyboard shortcut, shell command) opens as a popover anchored to its row.
- Every advanced control has a safe default that the pane's Restore Defaults covers.
- **Hide or dim.** Dim a row when a switch above turns its feature off. Hide rows that do not apply
  to the current mode or mouse. A control is hidden for the mouse only when the mice it describes (the chosen mouse; for All Mice
  every known mouse, once all are connected), online with PureMouse running, report every capability
  it needs as false (`MouseScope.deciding`); unknown counts as
  available, and with no mouse known every control shows. A control the config already sets stays,
  captioned "Not supported by this mouse." (`ControlAvailability`: Scrolling's rows from
  `ScrollingLayout`, Pointer's from `PointerLayout`, an app's thumb wheel and the picker's
  haptics the same way). A section whose rows are all hidden goes too. An Advanced… sheet that
  shows only while something applies (Buttons, while a button is Hold and Move) closes by itself
  when that stops.

## Status menu and menu bar icon

- Clicking the icon shows an `NSMenu`, never a popover.
- The icon is a template image (black and clear, 18 pt), never coloured or badged. A changed state
  (paused, off) is a different shape, not a colour.
- People choose whether the icon shows (General › Show in menu bar). Nothing depends on it
  except low-battery notifications, which live in the menu app and stop while the icon is hidden.
  With the icon hidden, opening PureMouse from the Finder opens Settings.
- Order: device header, attention rows (only while active), then the most used items, Settings…,
  "Settings for <app>…" (for the app in use, when there is one), Quit PureMouse. Separators between
  groups; submenus only for presets, one level deep.
- Unavailable **commands** are disabled, not hidden; **status** rows that do not apply are hidden.
- **Symbols.** None by default. macOS 27 shows menu icons only for key items: the device header is
  the one key item, set with `preferredImageVisibility = .visible` on macOS 27. Within a group, all
  items have a symbol or none do; the menu reads correctly on macOS 14–27 with or without them.
- **⌥ alternates** use one modifier and are never the only way to do something: the detail line's
  facts are in Settings (pointer speed on Pointer, wheel mode on Scrolling, version in About), Show
  Log in Finder is in General › Advanced…, and Hide Menu Bar Icon is General › Show in menu bar.
  Reload Config is the exception: the config applies on save, so it stays as the ⌥ recovery. A
  manual reload re-runs adoption retries and re-arms the permission poll, which saving identical
  bytes does not.

## Permissions and first run

- PureMouse never blocks: without a permission the mouse keeps its native behaviour, and the rows
  that need it say so.
- First run opens Settings on Mouse. Missing permissions show as General's Permissions rows and as
  a notice on the panes that need them: state (Allowed, Not allowed), one sentence on what it is
  for, and one button that opens the exact pane of System Settings.
- A grant made soon after is detected without the person doing anything (the daemon polls and
  restarts itself); the row turns to Allowed in place. No "quit and reopen". The daemon checks for
  10 minutes after start, wake, reload, a control change or a Bluetooth attach
  (`Daemon.pollPermissions`), so a later grant needs Reload Config or a restart.
- A grant that stops working after an update shows as **Not allowed** with the same button, never
  as a switch that looks on.
- No alert at launch, no mock of the system dialog, no Cancel on the step.

## Empty, error and feedback states

- An empty state is a `ContentUnavailableView` with what is missing and one next step, as a
  button where one exists: no mouse found, Bluetooth off, PureMouse paused or off, Logi Options+
  running, permission not allowed, no apps added.
- An error shows next to the control it concerns. Alerts only for an actionable failure or an
  action that cannot be undone (Reset All Settings…, Use Last Working Config…); never at launch,
  never for information.
- A destructive action chosen on purpose is confirmed with a verb button, without the destructive
  style; Cancel is never the default.
- **Notices** (`BannerPlan`): a pane shows at most one banner, untinted, with "N more notices"
  opening General.

## Motion, sound and accessibility

- System animation only; nothing animates on frequent interactions, and nothing relies on motion
  to say something. Under Reduce Motion, no scale, zoom or bounce. No sounds.
- Windows, panes, sheets and popovers open with nothing focused (house rule). Every control is
  reachable by Tab and by Full Keyboard Access, has a distinct accessibility label, and is at
  least 20 × 20 pt. Tooltips are under 75 characters and never repeat the control's name.
- **Fit.** Each default view fits within 600 pt of content height at the 600 pt window width,
  with one-mouse and two-mouse fixtures (and with a mouse chosen). A fresh install shows no advanced
  content.
- **Test matrix** for a UI change: light and dark; Increase Contrast; Reduce Transparency; the
  Liquid Glass slider at both ends (clear and tinted); Reduce Motion; Show Borders; Full Keyboard
  Access; VoiceOver on every symbol-only control. Fix legibility with system settings, never by
  adding a background. A capture matrix needs the system settings changed by a person at the
  Mac; light and dark captures of every default view and sheet run over SSH (AGENTS.md).
- **Checks that run without a person.** `UIChromeScanTests` (above), `MenuPlanTests` (the status
  item's spoken label), and `PUREMOUSE_DEV_AX_DUMP=1` on a macOS 27 Mac, which lists every
  control's role, label and size for each tab, Mouse segment and (through the other
  `PUREMOUSE_DEV_*` hooks) each sheet and popover, and fails on a control with no label, an unnamed
  button, two controls with one label in a window, or a control under 20 × 20 pt. It does not hold
  the system's own parts to the size or the label: a slider and a mini switch (16-18 pt, drawn by
  AppKit; the row takes the click), the window's close, zoom and
  minimise buttons, and a scroll bar's arrows and pages.
- **Captures** and README screenshots come from a macOS 27 host running a build linked against
  the macOS 27 SDK (`scripts/verify-bundle.sh` checks the SDK), since the system restyles at run
  time.

## Device card

On Mouse > Buttons, a mouse with a drawing ([ADR 13](adr/0013-silhouettes.md)) shows a card above
the rows: the drawing, the mouse's name and a caption line. Nothing else shows it: not Scrolling,
Pointer, All Mice, a mouse of no listed model, the 2S, MX Vertical, Lift, MX Ergo or a G series.

- **Parts.** Each part of the drawing is an accessible button with its own label ("Back button,
  Mouse Default") and a hint. A click on a button's part selects its row: the row scrolls into
  view and is marked, and a capture, or opening a row's picker, selects it too. The thumb wheel
  has no button, so it opens Scrolling > Thumb Wheel. The main wheel has two things to open, so it
  is a two-item menu, Wheel Click and Scrolling Settings; VoiceOver gets both as actions.
- **Arriving.** A part that leaves the page goes through `MouseSelection.select`, then scrolls to
  its section, outlines it for about a second and a half (not at all under Reduce Motion, which
  also skips the fade) and moves VoiceOver there. The selection clears when Buttons is left or
  another mouse is chosen.
- **States.** Hover is the accent colour at 0.6 opacity and selection is the solid accent colour,
  each filling the part's outline; neither moves anything. The caption slot is fixed at two lines,
  so hovering never changes the card's height, and it names the part and what a click does.
- **Marking a row (#133).** A grouped `Form` ignores `listRowBackground`, so a row is marked in
  its own content: a tinted capsule behind it and its title in the accent colour. The selected row
  is a light tint and Find by Pressing's match is stronger, for a few seconds. The mark must be
  visible in both appearances.
- **Size.** The art is drawn at 1.5x (150 x 186 pt); every part's cell is at least 20 x 20 pt
  there. The Buttons pane must stay within 600 pt of content with the card (check the capture:
  PNG height / 2 - 88).
- **Scan.** No size or colour literals (`UIChromeScanTests`): frames come from constants, colours
  from `.tint` and the semantic styles. A closure that calls a method is written `{ select($0) }`
  (Swift 6.3), and a macOS 27 API sits in `#if compiler(>=6.4)`.
- **Hooks (debug).** `PUREMOUSE_DEV_HOVER=<part>`, `PUREMOUSE_DEV_BUTTON=<button>` and
  `PUREMOUSE_DEV_FOUND=<button>` on Buttons; `PUREMOUSE_DEV_ARRIVAL=thumbWheel|mainWheel` (with
  `PUREMOUSE_DEV_ARRIVAL_HOLD=1` to keep the outline) on Scrolling.

## Support, About and the icon

- About shows the icon, name, version, Check for Updates with the **Check for updates
  automatically** switch beside it, links and one **Support PureMouse**
  link to GitHub Sponsors. Support appears nowhere else: no prompts, badges or reminders.
- The app icon is the Icon Composer document (`assets/AppIcon.icon`, AGENTS.md). Check it at 16
  to 1024 px in default, dark, clear and tinted, in the Dock, Finder, About and alerts.

## Where PureMouse goes further

System Settings › Mouse adjusts blind: a slider with no sample, no undo, nothing tied to the app in
use. PureMouse goes further only where the HIG's own principles (feedback, forgiveness, direct
manipulation) lead and the system still draws everything: standard controls, no new chrome, no idle
cost. Planned or built (epic #114):

- **Try it.** A collapsed "Try it" disclosure under Feel and Speed on Scrolling reveals a short
  plain-text scroll area, so smoothing is felt where it is set. Trackpad shows its gestures; Mouse
  shows nothing.
- **Undo.** ⌘Z and ⇧⌘Z undo and redo each settings change, named in the Edit menu ("Undo Pointer
  Speed"). One slider drag is one step.
- **Settings for the app in use** (built). The status menu offers "Settings for <app>…" below
  Settings… for the frontmost app (not Finder, the Dock or any PureMouse bundle, nor one without a
  bundle identifier), opening its sheet in Apps. `NSWorkspace.shared.frontmostApplication` is read
  once as the menu opens, with no observer or timer; opening a status item's menu does not
  activate PureMouse, so it still names the app in use.
- **Feel a haptic.** Choosing a haptic action in the picker plays it once on a mouse with haptics,
  as Trackpad's Click slider does.

Not adopted: a 3D or photographic mouse map with glowing callouts (the device card stays original
art, with no markers or callouts, #56); an acceleration curve editor (macOS owns acceleration, so it
would duplicate System Settings); a floating per-app indicator (it polls and covers content);
display-density DPI hints and live gesture highlighting (more text and motion than they earn).

## Layout

| Place | Shown by default | Advanced |
|---|---|---|
| General | Status (PureMouse running/paused/off, Start or Stop, active notices), Open at login, Show in menu bar, Low battery notification, Permissions | Advanced… sheet: Work with Universal Control, Config file, Log, Reset All Settings… |
| Mouse header | Buttons, Scrolling, Pointer segments; mouse pop-up with two or more mice; Find by Pressing… and the device card on Buttons | — |
| Mouse › Buttons | One row per button with its action | Gesture directions (disclosure, collapsed, caption summarises them; choosing Hold and Move expands it); Other controls (disclosure); Advanced… sheet, only while some button anywhere is Hold and Move: gesture Distance and Repeat |
| Mouse › Scrolling | Smooth scrolling, Feel, Speed; Main Wheel: Reverse direction, Wheel mode, SmartShift; Thumb Wheel: Action (Turn left/right when Custom); each when the mouse has it | Advanced… sheet, each row only when it applies: Acceleration, Glide, Hold Shift to scroll sideways (dimmed while smooth scrolling is off); Switches at (while SmartShift is on); thumb wheel Reverse direction (when it scrolls here or in some app), Swap directions and Turn distance (when it has actions), Speed (when it scrolls) |
| Mouse › Pointer | Pointer Speed slider with its value; Presets summary row; both only when the mouse can adjust its speed (else one "Not supported by this mouse." row, unless a value is set) | Exact value (disclosure); Edit Presets… sheet (also opened from the menu) |
| Apps | App list with summaries, Add App (bordered pull-down) in the footer, routing note; empty state with an Add App… button that opens the Applications panel | Each app opens in a sheet; inside it, gesture directions, other controls and more thumb wheel options are disclosures |
| About | Icon, name, version, Check for Updates, Check for updates automatically (switch), links, Support PureMouse | — |
| Status menu | Device header, attention rows when active, Update to X.Y.Z… with Skip This Version under it (while a newer release is known), Smooth Scrolling, Pointer Speed, Start/Pause/Resume, Settings…, Settings for <app>… (the frontmost app, if any), Quit PureMouse | ⌥: detail line, Show Log in Finder, Hide Menu Bar Icon |

## Sources

HIG pages: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets),
[Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls),
[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar),
[Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles),
[Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts),
[Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Also [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
[`NSMenuItem.preferredImageVisibility`](https://developer.apple.com/documentation/appkit/nsmenuitem/preferredimagevisibility),
WWDC25 sessions 310 and 356, and WWDC26 sessions 102, 250 and 289.

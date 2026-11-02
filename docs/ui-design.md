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
- **Let the system draw.** No explicit font sizes, control widths or heights, literal corner radii,
  materials, `glassEffect`, `.buttonStyle(.glass)`, backgrounds or colour literals. No
  `.controlSize` overrides except `.mini` on a switch, if a grouped form's default ever renders
  larger than System Settings' (check it in a capture), and never `.extraLarge`. Scan-tested:
  `.system(size:`, numeric `.frame(width:`/`height:` on controls, `Color.<name>`, `.white`,
  `.black` outside symbol rendering, `glassEffect`.
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
- No sheet opens from a sheet; inside a sheet, use disclosures.
- Every advanced control has a safe default that the pane's Restore Defaults covers.
- **Hide or dim.** Dim a row when a switch above turns its feature off. Hide rows that do not apply
  to the current mode or mouse.

## Status menu and menu bar icon

- Clicking the icon shows an `NSMenu`, never a popover.
- The icon is a template image (black and clear, 18 pt), never coloured or badged. A changed state
  (paused, off) is a different shape, not a colour.
- People choose whether the icon shows (General › Show in menu bar). Nothing depends on it: with
  the icon hidden, opening PureMouse from the Finder opens Settings.
- Order: device header, attention rows (only while active), then the most used items, Settings…,
  Quit PureMouse. Separators between groups; submenus only for presets, one level deep.
- Unavailable **commands** are disabled, not hidden; **status** rows that do not apply are hidden.
- **Symbols.** None by default. macOS 27 shows menu icons only for key items: the device header is
  the one key item, set with `preferredImageVisibility = .visible` on macOS 27. Within a group, all
  items have a symbol or none do; the menu reads correctly on macOS 14–27 with or without them.
- **⌥ alternates** use one modifier and are never the only way to do something: the detail line is
  in General › Status, Show Log in Finder in General › Advanced…, and Hide Menu Bar Icon is
  General › Show in menu bar. The menu has no Reload Config: the config applies on save.

## Permissions and first run

- PureMouse never blocks: without a permission the mouse keeps its native behaviour, and the rows
  that need it say so.
- First run opens Settings on Mouse. Missing permissions show as General's Permissions rows and as
  a notice on the panes that need them: state (Allowed, Not allowed), one sentence on what it is
  for, and one button that opens the exact pane of System Settings.
- The grant is detected without the person doing anything (the daemon polls and restarts itself);
  the row turns to Allowed in place. No "quit and reopen".
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
  with one-mouse and two-mouse fixtures. A fresh install shows no advanced content.
- **Test matrix** for a UI change: light and dark; Increase Contrast; Reduce Transparency; the
  Liquid Glass slider at both ends (clear and tinted); Reduce Motion; Show Borders; Full Keyboard
  Access; VoiceOver on every symbol-only control. Fix legibility with system settings, never by
  adding a background.
- **Captures** and README screenshots come from a macOS 27 host running a build linked against
  the macOS 27 SDK (`scripts/verify-bundle.sh` checks the SDK), since the system restyles at run
  time.

## Support, About and the icon

- About shows the icon, name, version, Check for Updates, links and one **Support PureMouse**
  link to GitHub Sponsors. Support appears nowhere else: no prompts, badges or reminders.
- The app icon is the Icon Composer document (`assets/AppIcon.icon`, AGENTS.md). Check it at 16
  to 1024 px in default, dark, clear and tinted, in the Dock, Finder, About and alerts.

## Layout

| Place | Shown by default | Advanced |
|---|---|---|
| General | Status (PureMouse running/paused/off, Start or Stop, active notices), Open at login, Show in menu bar, Low battery notification, Permissions | Advanced… sheet: Work with Universal Control, Config file, Log, Reset All Settings… |
| Mouse header | Buttons, Scrolling, Pointer segments; mouse pop-up with two or more mice; Find by Pressing… and the device card on Buttons | — |
| Mouse › Buttons | One row per button with its action | Gesture directions (disclosure, collapsed, caption summarises them); Other controls (disclosure); Advanced… sheet: gesture distance and repeat |
| Mouse › Scrolling | Smooth scrolling, Feel, Speed; Reverse direction, Wheel mode, SmartShift (when the mouse has them); thumb wheel Action (Turn left/right when Custom) | Advanced… sheet: acceleration, glide, Shift for sideways; SmartShift threshold; thumb wheel reverse, turn distance, speed |
| Mouse › Pointer | Pointer Speed slider with its value; Presets summary row | Exact value (disclosure); Edit Presets… sheet (also opened from the menu) |
| Apps | App list with summaries, Add App in the footer, routing note; empty state with Add App | Each app opens in a sheet; inside it, gesture directions, other controls and more thumb wheel options are disclosures |
| About | Icon, name, version, Check for Updates, links, Support PureMouse | — |
| Status menu | Device header, attention rows when active, Smooth Scrolling, Pointer Speed, Start/Pause/Resume, Settings…, Quit PureMouse | ⌥: detail line, Show Log in Finder, Hide Menu Bar Icon |

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

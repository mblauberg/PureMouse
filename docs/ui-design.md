# UI design

How PureMouse's menu and Settings look and behave. Words are in `docs/ui-language.md`. A change
to the UI follows this page, and a change to this page lands with the UI it changes. Rules come
from Apple's Human Interface Guidelines (HIG, revised June 2026) and macOS 27 unless marked
**house rule**; the sources are listed at the end.

## Principles

The owner's bar: PureMouse is "reliable, lightweight, intuitive, modern, macOS native feeling,
clean, minimalistic, configurable, flexible and easy to maintain".

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
  handle and sizes to the pane: content at most 600 pt, never taller than the screen
  ([Sizing](#implementation)).
- It reopens on the last tab and segment (`SettingsSelection`) and remembers its position, not its
  size: the size always comes from the pane (no frame autosave).
- Mouse's header strip has a leading slot for the mouse pop-up (`MousePopUp`: All Mice, then each
  known mouse), shown with two or more mice known or any `devices` entry. Its closed text is the
  mouse's name, in a pop-up as wide as the name needs, up to 240 pt and the width the strip leaves it
  (as a macOS pop-up draws, no dead space after the name), then cut with an ellipsis that keeps the
  chevron (one line, never over the centred segments). The Apps note ("Apps are the same for every mouse.") is the
  pop-up's last menu item, a tooltip and its accessibility hint rather than a line under it: a line
  costs 15 pt in a strip every segment shares, and Scrolling has 6 pt to spare. "Settings you don't
  change follow All Mice." is the menu's other note, said once. A pane under a chosen mouse
  (and an app's page) marks changes, not inheritance (`InheritedValue`): a row that inherits looks
  exactly as it does under All Mice, with the same control, full contrast and its usual help caption;
  a row with its own value adds the line "Set for this mouse." ("Set for this app.") and an inline
  link, "Use All Mice Setting" ("Use Mouse Setting"), moves its help to the tooltip, and offers
  the same command in its context menu and as a VoiceOver action. No row reserves a hidden slot, so
  every trailing control ends at the form's trailing edge and a slider track never moves between
  scopes. A mouse's pane is never taller than the same pane under All Mice, except by that one line
  on changed rows.
- **An app's page** (Apps; `AppPage`) replaces the list in the tab, and is built like the Mouse tab: a
  fixed header strip over the segment's grouped form. The strip has **‹ Apps** at the leading edge
  (the button, ⌘[ and Esc all go back to the list), the **Buttons | Scrolling** segments in the
  middle, and the app's icon and name at the trailing edge (its bundle identifier is the tooltip).
  There is no Pointer segment: Thumb Wheel is a group under Scrolling, after Custom scrolling.
  Choosing a segment writes nothing, and each app opens on Buttons. The footer's leading edge
  holds **Remove App…**, which asks first. The page marks changes as a mouse's panes do (model C,
  `InheritedValue`), with the source "Mouse Settings": a row the app leaves alone shows the value
  that applies, which is the mouse's own when the mouse has one and not the top level's, and is
  "Varies by Mouse" when the known mice resolve the control differently (`AppModel.knownMice`,
  `ConfigScope.resolved`; the pop-up's first entry then reads "Same as Mouse Settings (Varies by
  Mouse)"). A row the app sets reads "Set for this app." with "Use Mouse Setting", which removes
  only that app's key under `apps.<id>`; Mouse Default is a value of its own, distinct from
  leaving the row alone, and its caption is the one the Mouse page gives (a gesture's "Click: Mission
  Control, 1 direction set.", worked out from the app's directions over the mice's). Turning
  Custom scrolling on starts from the first mouse's values; its caption describes the on state
  ("Gives this app its own scrolling speed and glide.") whatever the smooth-scrolling settings are,
  and Glide is disabled only while smooth scrolling is off on every mouse the app may run with.
  The Speed and Glide sliders put the knob at the first mouse's value and read "Varies" (VoiceOver
  "Varies by Mouse") while the mice differ; the short word keeps the track where it is on Mouse ›
  Scrolling, as does Turn distance's "Varies" beside its stepper. "More thumb wheel options" shows
  while the rows apply on any mouse the app may run with, not only the first. A suggestion for a
  well-known app (Safari: "The thumb wheel switches tabs.") is an ordinary form row at the top of
  Scrolling, "Suggested for Safari" with the words under it and a bordered **Use Suggested
  Settings** button at the trailing edge: no symbol, no banner. Each
  Apps row names the areas its app changes in words ("Buttons, Scrolling", or "No custom
  settings"), never by colour. "Settings for <app>…" in the status menu opens the same page.
  An added app is not written until a setting is chosen (its row says so until Settings closes).
  Names are looked up without icons (`AppIdentities`); an icon loads when its frame meets the scroll
  view's visible bounds (`AppIcon`: a grouped form builds every row, so `onAppear` is not enough, and
  macOS 14 lacks `onScrollVisibilityChange`), and Applications is never listed (adding goes through
  an open panel or the running apps). Esc and Return still act on a sheet first. The default content is within 600 pt at one and two
  mice; a long segment scrolls under the strip.
- ⌘W closes it, and closing it quits the helper. Esc dismisses a sheet, and on an app's page goes
  back to the Apps list; Return takes the sheet's default button.
- Nothing is placed behind the toolbar or the tab bar: no backgrounds, materials or
  `NSVisualEffectView`. The scroll edge effect stays automatic.

## Forms and controls

- Every pane is a `Form` with `.formStyle(.grouped)` of `LabeledContent` rows. Section headers are
  Title Case (`docs/ui-language.md`); grouped forms no longer upper-case them.
- Controls, in order of preference: switch, pop-up menu, segmented control (four segments or
  fewer, a fixed count, all text or all symbols), slider (minimum leading, end labels, live value),
  stepper, `ContentUnavailableView`. A pop-up's **Custom** entry may reveal the rows it needs.
- **One pop-up look.** Every pop-up (an action row on Buttons, the thumb wheel's Action, an app's
  "Same as Mouse Settings" rows) is drawn the same way (`PopUpLabel`): the value, then the up/down
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
  width and its readout's minimum width, and the shortcut and command editors' width (small
  sheets, narrower than the others). Other sheets share one width
  (`SettingsWindowController.sheetWidth`) and take their height from their content.
- **Custom shapes are concentric.** Prefer a system container (form section, `GroupBox`). A custom
  rounded view, such as the device card, uses `ConcentricRectangle` (macOS 26+) so it follows the
  window's radius; the macOS 14–15 branch may use one named radius constant.
- **Colour.** Semantic system colours only. State is a symbol plus a word, never colour alone.
  Tint goes on one control at most (the pane's primary action, if any). Symbols: hierarchical by
  default, `.multicolor` only where the colour means something (a warning, a battery level),
  variable colour only for a changing value (battery).
- **Typography.** Text styles only; macOS has no Dynamic Type, so nothing smaller than `.caption`.

The main wheel's rows always show a concrete value (`WheelDefaults`): while nothing is set,
Reverse direction is off, Wheel mode is the mode the mouse reports (Ratchet if it reports none)
and SmartShift is on, with no "Using the mouse's own setting." caption (Switches at, in Advanced…,
keeps it). A key is written only when the choice differs from what the scope would have without
it: the value an explicit All Mice setting gives a mouse, else that default. A choice equal to it
removes the key; SmartShift on over an inherited off writes 12. Wheel mode is the exception: it is
always written, because the daemon does not restore the mouse's own mode when the key goes, and
only a mouse's choice equal to an explicit All Mice mode removes it.

## Disclosure

Each level has one mechanism, and each label says what it reveals.

- **Advanced…** A push button at the trailing edge of the pane's last row (`PaneFooter`, in the
  last section's footer, so it scrolls with the form; nothing is pinned to the window's bottom
  edge). Restore Defaults sits at the leading edge of the same row. Either is optional. Both end
  flush with the grouped boxes, as Find by Pressing… does in the strip above.
- **Advanced sheet** (`AdvancedSheet`): a title, a grouped form and one **Done** button. Its
  settings apply live, like the pane's, so there is nothing for Cancel to undo (house rule: System
  Settings › Mouse › Advanced… does the same; the HIG pairs Done with Cancel for sheets that hold
  edits). A sheet that holds edits until confirmed, such as the shortcut recorder, has Cancel and a
  verb. Each sheet has a fixed width and fits its content.
- **Disclosure triangle** only for a control's own children (gesture directions, Exact value);
  at most one per row.
- **⌥ alternates** only in the status menu, and each also has a home in Settings (see Status menu).
- No sheet opens from a sheet; inside a sheet, use disclosures. The editors (keyboard shortcut,
  shell command) are always sheets, an app's page included: it is a page of the Apps tab, not a sheet.
- Every advanced control has a safe default that the pane's Restore Defaults covers.
- **Restore Defaults** returns the pane's own keys to the one default set
  ([docs/configuration.md#defaults](configuration.md#defaults)), which a first run, Reset All
  Settings and `{}` also give: Scrolling's leaves smooth scrolling on at Balanced, Buttons' leaves
  Back, Forward and the gesture bound as the set says, Pointer's leaves the mouse's own DPI. A
  pane never offers a different "default" of its own; Feel shows Balanced on a fresh config.
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
- People choose whether the icon shows (General › Show in menu bar). Nothing depends on it: with
  the icon hidden the menu app keeps running without a status item (windowless), so low-battery
  notifications and the daily update check carry on, and both switches stay available. The
  footprint of that process is budgeted ([ADR 10](adr/0010-menu-memory-budgets.md)). Opening
  PureMouse from the Finder opens Settings, and Show in menu bar there brings the icon back.
- Order: device header, attention rows (only while active), then the most used items, Settings…,
  "Settings for <app>…" (for the app in use, when there is one), Quit PureMouse. Separators between
  groups; submenus only for presets and Easy-Switch, one level deep. Easy-Switch (planned, #155) is
  shown only for a mouse that reports host switching: one row holds both the status (a checkmark
  on this Mac) and the command, where flat "Switch to Computer N" items would add rows for an
  occasional task. With two or more mice it stays one submenu, with a section header per mouse.
- **Quiet when applied** (planned, #155). The menu reports a problem, not that all is well. The
  header's second line reads "Applying settings…" or "Settings not applied" only while that is
  true, with an Apply Settings Again attention row only while not applied. The time of the last
  apply ("Settings applied at 09:14") is on the ⌥ detail line.
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
- **No mouse.** With PureMouse running and not paused, and no mouse known (none adopted, none waiting, none in the config), the Mouse
  pane has no header (no segments, no Find by Pressing…) and no boxed card: a plain "No Mouse Found"
  `ContentUnavailableView` with one bordered button, Open Bluetooth Settings…. General's row reads
  "No mouse found." with a caption and no button. A Bluetooth mouse that is seen but waiting for
  Input Monitoring is not "no mouse": the pane, General and the menu say "<Mouse> is waiting for
  Input Monitoring" and offer Allow Input Monitoring…. While that notice shows, General's
  Permissions row is status only. The row reads "Not needed" when no Bluetooth mouse is in play.
  A pane's content stays within 600 pt.
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
  least 20 × 20 pt. Tooltips are under 75 characters and never repeat the control's name. Check
  focus with keyboard navigation (`AppleKeyboardUIMode`) both on and off.
- **Fit.** Each default view fits within 600 pt of content height at the 600 pt window width,
  with one-mouse and two-mouse fixtures (and with a mouse chosen). A fresh install shows no advanced
  content.
- **Test matrix** for a UI change: light and dark; Increase Contrast; Reduce Transparency; the
  Liquid Glass slider at both ends (clear and tinted); Reduce Motion; Show Borders; Full Keyboard
  Access; VoiceOver on every symbol-only control. Fix legibility with system settings, never by
  adding a background. A capture matrix needs the system settings changed by a person at the
  Mac; light and dark captures of every default view and sheet run over SSH
  ([Development](development.md#dev-hooks)).
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
the rows: the drawing and, beside it, the mouse's name in `.title3` semibold and a caption, the two
centred on the card as one group. Nothing else shows it: not Scrolling or Pointer, and not a mouse
with no listed model. A trackball (MX Ergo), a vertical mouse (MX Vertical, Lift), the 2S, a G
series mouse and any unknown product get no card and keep every row in the list (#56).

- **Which mouse.** The chosen mouse shows its own card. Under All Mice the card shows only when
  every known mouse is the same model (two MX Master 3S do; one mouse does), whether or not a
  pop-up is offered. A mouse with no key or no listed model counts as a different one, so an MX
  Master 3S with an unknown mouse has no card, whether that mouse is a known one the art has no
  model for or a reported one with no device key (it is not in the pop-up, but still counts).
- **Parts.** Each part of the drawing is an accessible button with its own label ("Back button,
  set to Mouse Default") and a hint. A click on a button's part selects its row: the row scrolls
  into view and is marked, and a capture, or opening a row's picker, selects it too. The thumb
  wheel has no button, so it opens Scrolling > Thumb Wheel. The main wheel has two things to open,
  so it is a two-item menu, Wheel Click and Scrolling Settings; VoiceOver gets both as actions. On
  the MX Master 3 and 3S the thumb rest is the gesture button; on the MX Master 4 the gesture
  button is a small key of its own ahead of Forward and Back and the thumb rest is the haptic
  panel (a row only when the mouse reports it). Both list the gesture button in the same row order.
- **Arriving.** A part that leaves the page goes through `MouseSelection.select`, then scrolls to
  its section, outlines it for about a second and a half and moves VoiceOver there. Under Reduce
  Motion the outline still shows for the same time: it appears and goes without the fade. Each
  arrival has its own timeout, so an earlier one cannot clear a later one's outline
  (`ArrivalOutlineState`). The selection clears when Buttons is left or another mouse is chosen.
- **States.** One continuous hover over the drawing finds the part under the pointer from its hit
  cells, which partition the art. Hover fills the part's outline with the accent colour at 0.6
  opacity and selection fills it solid; each is edged in the accent colour, so a small part reads
  in both appearances. Neither moves anything. The caption slot is two lines high and as wide as
  the widest caption the mouse can show (up to 240 pt), so the drawing and text centre on the card
  and hovering never moves or resizes it. A caption is a full sentence ("The Back button is set
  to Mouse Default.", "Click to open the thumb wheel's scrolling settings.").
- **Find by Pressing.** A press that finds a row marks the row and lights its part on the drawing
  in the state a click on the part gives, with the caption to match.
- **Marking a row (#133).** A grouped `Form` ignores `listRowBackground`, so a row is marked in
  its own content: a row-high rounded band behind it (a shape in a stack, since the scan keeps
  `.background` out of Settings) in the accent tint, 18 % for the selected row and 30 % with a 1 pt
  accent stroke for Find by Pressing's match, which stays a few seconds. The band is 4 pt inside
  the form's box on every side, the first and last rows included. The title stays primary,
  for contrast. The mark must be visible in both appearances.
- **Size.** The art is drawn at 1.5x (150 x 186 pt); every part's cell is at least 20 x 20 pt
  there. The Buttons pane must stay within 600 pt of content with the card (check the capture:
  PNG height / 2 - 88).
- **Other controls.** The disclosure lists the controls Kit names beyond the named buttons (the
  DPI button) and any control the config binds. A control with no name is not listed on its own: a
  hex ID is no button anyone can find. One the config binds, or Find by Pressing just found, gets
  a row titled "Button N" (N its control ID in decimal), never "Control 0x0100".
- **Scan.** No size or colour literals (`UIChromeScanTests`): frames come from constants, colours
  from `.tint` and the semantic styles. A closure that calls a method is written `{ select($0) }`
  (Swift 6.3), and a macOS 27 API sits in `#if compiler(>=6.4)`.
- **Hooks (debug).** `PUREMOUSE_DEV_HOVER=<part>`, `PUREMOUSE_DEV_BUTTON=<button>` and
  `PUREMOUSE_DEV_FOUND=<button>` on Buttons; `PUREMOUSE_DEV_ARRIVAL=thumbWheel|mainWheel` (with
  `PUREMOUSE_DEV_ARRIVAL_HOLD=1` to keep the outline) on Scrolling.
- **Art.** Regenerate the drawings and the hit geometry with `scripts/make-silhouettes.sh`.

## Support, About and the icon

- About shows the icon, name, version, Check for Updates with the **Check for updates
  automatically** switch beside it, links and one **Support PureMouse**
  link to GitHub Sponsors. Support appears nowhere else: no prompts, badges or reminders.
- The app icon is the Icon Composer document (`assets/AppIcon.icon`,
  [Development](development.md#icon)). Check it at 16
  to 1024 px in default, dark, clear and tinted, in the Dock, Finder, About and alerts.

## Where PureMouse goes further

System Settings › Mouse adjusts blind: a slider with no sample, no undo, nothing tied to the app in
use. PureMouse goes further only where the HIG's own principles (feedback, forgiveness, direct
manipulation) lead and the system still draws everything: standard controls, no new chrome, no idle
cost. Planned or built (epic #114):

- **Try it** (built). A collapsed "Try it" disclosure under Feel and Speed on Scrolling reveals a
  plain-text scroll area (a ScrollView of "Line 1" to "Line 40", `Scrolling sample` to VoiceOver, 120
  pt tall: a ScrollView has no intrinsic height, so `ScrollingPane.sampleHeight` names it), and the
  window refits. Smoothing is felt where it is set. Collapsed it adds one row, and Scrolling must stay
  within 600 pt for a mouse with a thumb wheel (checked by capture); if it did not, Try it is cut. Trackpad shows
  its gestures; Mouse shows nothing. `PUREMOUSE_DEV_TRY_IT=1` opens it (debug).
- **Undo.** ⌘Z and ⇧⌘Z undo and redo each settings change, named in the Edit menu ("Undo Pointer
  Speed"). One slider drag is one step.
- **Settings for the app in use** (built). The status menu offers "Settings for <app>…" below
  Settings… for the frontmost app (not Finder, the Dock or any PureMouse bundle, nor one without a
  bundle identifier), opening its page in Apps. `NSWorkspace.shared.frontmostApplication` is read
  once as the menu opens, with no observer or timer; opening a status item's menu does not
  activate PureMouse, so it still names the app in use.
- **Feel a haptic.** Choosing a haptic action in the picker plays it once on a mouse with haptics,
  as Trackpad's Click slider does.

Not adopted: a 3D or photographic mouse map with glowing callouts (the device card stays original
art, with no markers or callouts, #56); an acceleration curve editor (macOS owns acceleration, so it
would duplicate System Settings); a floating per-app indicator (it polls and covers content);
display-density DPI hints and live gesture highlighting (more text and motion than they earn).

## Planned structure (#155)

The agreed target for epic #155 (with #153 and #154), not built. Each slice moves its part into the
rules above when it ships, and this section shrinks as it does. The decisions are
[ADR 23](adr/0023-receiver-pairing-is-the-one-persistent-write.md) (receiver pairing) and
[ADR 24](adr/0024-one-action-model.md) (the action model); the words are in
[UI language](ui-language.md#planned-155).

Four tabs stay (General, Mouse, Apps, About), with no Rings, Macros, Packs, Automation or Devices
tab and no new Mouse segment. What does something is an action in the one picker.

```
Menu bar icon (NSMenu)
├─ Device header: second line "Bolt · 80%" | "Applying settings…" | "Settings not applied" | "Off in <App>"
├─ Attention rows, only while true: Apply Settings Again · Allow… · Update to X.Y.Z…
├─ Smooth Scrolling · Pointer Speed ▸ · Easy-Switch ▸ (only if the mouse reports it) · Pause PureMouse
├─ Settings…  ·  Settings for <frontmost app>…  ·  Quit PureMouse
└─ ⌥: detail line (adds "Settings applied at 09:14") · Reload Config · Show Log in Finder · Hide Menu Bar Icon

Settings
├─ General: Status (PureMouse; one row per device with (i) → About This Mouse sheet; a receiver row
│            with (i) → Receiver sheet: Pair a Mouse…, Unpair…, last slice) · Open at login ·
│            Show in menu bar · Low battery notifications · Permissions ·
│            Advanced…: Universal Control, Config file [Open] [Export Settings…] [Import Settings…],
│            Log, Reset All Settings…
├─ Mouse [Buttons | Scrolling | Pointer]
│   ├─ Buttons: one row per button, its pop-up the click; Double-click and Hold as child rows once
│   │           added; Other controls; Advanced…: Ignore repeated clicks, Hold and Move
│   ├─ Scrolling: Advanced… gains Modifier Keys (Shift, Option, Command, Control) in place of
│   │             "Hold Shift to scroll sideways"
│   └─ Pointer: unchanged
├─ Apps: list ("Buttons, Scrolling" or "Off") → app page: Use PureMouse in this app (switch; dims the
│        rest) · Suggested banner · Buttons, the app's actions first · Scrolling, with Modifier Keys
│        collapsed · Remove App…
└─ About: unchanged
```

| Feature | Home |
|---|---|
| Recovery you can see | Menu header line, attention row, General notice; only while not applied |
| Click, Double-click, Hold | The button row and its child rows; More Ways to Press at the foot of the row's picker |
| Button plus scroll | Hold → Hold and Scroll, using the thumb wheel's pairs |
| Modifier plus scroll | Scrolling › Advanced…; collapsed on an app's Scrolling |
| Ignore repeated clicks | Buttons › Advanced…, per mouse; milliseconds stay in config |
| Off in this app | The app page's first row |
| Easy-Switch | Status in About This Mouse and the menu; Switch to Computer N in the picker |
| About This Mouse | General › Status, the mouse row's (i) |
| Drag Lock, Precise Pointer | Picker › Mouse: commands, not settings |
| Per-app actions (#154) | The app page's picker, the app's own section first |
| Sequence, Action Ring and new action types (#153) | Picker › Custom, one sheet each |
| Export, Import | General › Advanced…, beside Open Config File, and the File menu |
| Receiver pairing | The receiver row's (i), and No Mouse Found when a receiver is present |
| App Intents | Shortcuts and Spotlight; no Settings UI |

**Action model.** When I click, double-click or hold a control (in an app), do an action, each
trigger inheriting on its own from All Mice to the mouse to the app. A binding is a bare action,
which is its click, or a table of triggers ([ADR 24](adr/0024-one-action-model.md)).

- **A button's pop-up always shows its click action.** The gesture button reads "Mission Control",
  with Hold and Move as its Hold row. There is no "Several Actions" value.
- A trigger exists in the UI only once it is added (More Ways to Press), so a fresh install looks as
  it does today plus one device row in General › Status.
- The picker stays one popover: the app's actions first on an app page, sections over six rows fold
  to five and "Show All (N)", search matches everything, and it shows only what the mouse reports.
  No trigger strip, category strip, recents or favourites.
- An editor inside the Sequence or Action Ring sheet swaps that sheet's content; it never opens a
  second sheet.

## Implementation

Where the rules above live in `Sources/PureMouseSettingsUI` and `Sources/PureMouseAppSupport`.

- **Tabs.** `SettingsTab.shown` lists the tabs, so a new tab is one entry. Mouse is a fixed header
  strip (segments, Find by Pressing… on Buttons, a leading slot for the mouse pop-up) over its
  Buttons, Scrolling and Pointer segments (`MouseTab`), and holds only per-mouse settings. A
  request for `buttons`, `scrolling` or `pointer` opens Mouse on that segment (`SettingsPane`,
  `SettingsSelection`); a first run, or a stored tab not understood, opens Mouse (on Buttons the
  first time).
- **Sizing.** Tabs and segments are built the first time they show (`LazyPane`, `MouseTab`). Content
  is never taller than 600 pt (`SettingsWindowController.maxContentHeight`, the one number),
  or the screen's visible height less 80 pt where that is less (`LazyPane.maxHeight(on:)`, for the
  window's own screen, else the main one). The strip and the form together fit it: `PaneForm` is
  as tall as its rows up to `paneMaxHeight`, then scrolls (the cap is a bound on the form, not left
  to its content: an unbounded form has measured as tall as the screen, a blank 2400 pt window).
  The window asks each pane for its size when it fits (`IdealSized`: `PaneHost` answers with
  `sizeThatFits`, `MouseTab` adds the strip and gives the form what the strip leaves) and never reads
  `preferredContentSize` for it, which is only as fresh as the pane's last layout. Fitting the
  same content twice gives the same size. A pane whose height changes while shown calls
  `SettingsContext.refit()` (a nested `NSHostingController` updates its `preferredContentSize`
  without telling the tab controller), and `fitWindow` ignores a size that is zero or not finite.
  A disclosure opened on a full pane scrolls rather than growing the window. `AppPage` and
  `AdvancedSheet` take their form caps from the same number.
- **Advanced.** `PaneFooter` (Restore Defaults, Advanced…) opens an `AdvancedSheet`, which never
  opens another sheet. Hidden controls come from `ControlAvailability` over `MouseScope.deciding`,
  and Scrolling's rows from `ScrollingLayout`.
- **Scopes.** The mouse pop-up (`MousePopUp`, `AppModel.knownMice`, `MouseScope`) chooses the scope
  the panes edit (`AppModel.scope`, `scopeTarget`, remembered per user in defaults). Panes read
  `resolved` and write through `model.update(in: model.scopeTarget)`; a row uses its normal control
  in every scope. Do not read `primaryDevice` in a pane: `devices(in:)`, `liveDevice(in:)` and
  `primaryDevice(in:)` take the scope. Settings reads and writes a device through `ConfigScope`:
  `.device(key)` exists only for a key Kit accepts (`Config.isDeviceKey`), `set(_:at:in:)` refuses a
  section outside `Config.deviceSections`, writes `name` once when it creates an entry and prunes an
  entry left with only a `name`. The thumb wheel is read by layering (`thumbWheel(in:)`), never from
  the per-key merge, since its `action` resets `step` and replaces `left` and `right`.
  `binding(_:in:)` is the scope's own binding, not the one that applies.
- **Inherited and own values.** `InheritedValue` is the one type for any inherited value, for mice
  and apps. A row the scope sets itself gets an `InheritedOverride` note from `InheritedValue.note`
  (`RowLabel` or `DisclosureLabel` `note:`, `.overridable`); rows are `RowStanding`
  (`InheritedValue.swift`), so the note, the link and the spoken ", same as All Mice" come from one
  answer. The note text, link and VoiceOver wording are in [UI language](ui-language.md#glossary).
  `ScopeEditing.swift` holds the per-section helpers (`removeOverrides`, `restore…Defaults(in:)`,
  smooth scrolling, feel, presets).
- **Mouse Default.** A mouse's or an app's button row chooses Mouse Default as its own value,
  `"default"` (`Config.Binding.nativeValue`, `ButtonAction.mouseDefault`), beside "Same as …", which
  removes the key; under All Mice it removes the key. Under All Mice it is offered for every
  top-level button; on a mouse or in an app only for controls in `Config.nativeBehaviour(of:)`, the
  one table the daemon also performs from, though a `"default"` already set on another control
  stays in view (`PickerEntry.offersMouseDefault`).
  `buttonKey`/`removeButton` (`ConfigKeys.swift`) follow Kit's alias rule.
- **Global actions.** Reset All and the status menu stay global (`setDPI` without a target writes
  the top level). Settings' Pointer pane passes the mouse, and Find by Pressing and "use configured
  DPI" carry its key (`Control.device`, `Control.capture.device`), a press selecting that mouse's
  scope.
- **Buttons.** Mouse › Buttons and the Apps tab list a named button when a connected mouse reports it
  or the config binds it; with no report, those in `NamedButton.listedByDefault` (not the MX Master
  4's thumb panel) (`ButtonRows.named`). Haptic picker entries come from Kit's
  `HapticWaveform.allCases`; the menu only words them (`ActionCatalog.hapticLabel`).
- **Pointer speed.** The DPI the menu and Mouse › Pointer show is the mouse's live value (a
  `cycleDPI` press changes it without touching the config), then the configured one; a change made
  in the pane shows until the mouse reports it (`DPIReading`). Choosing the saved value changes
  nothing on disk, so `AppModel.setDPI` sends `useConfiguredDPI` ([companion.md](companion.md)).
- **Apps.** The Apps pane writes only `apps.<id>` keys (`AppSettings.swift`): each control's own key,
  removed for "Same as Mouse Settings" (an emptied app entry is pruned). An added app is not written
  until a setting is chosen; its row says so until Settings closes. Each app opens as a page of the
  tab (`AppPage`, in place of the list; see An app's page above), whose editors are sheets
  (`EditorPresentation`, read by `ThumbWheelRows` and the button rows). The value an unset control
  shows is the one the known mice resolve (`Applied`, over `AppModel.appInheritedScopes`), or
  "Varies by Mouse", for the thumb wheel's Turn distance and Swap directions too (`ConfigTree.thumbWheelKeysVarying`; Swap
  directions is an On/Off pop-up while it varies). The header is a view of its own above the form, as
  the Mouse tab's strip is (no scroll-edge line under it), with a fixed 16 pt top inset and its own
  height (`AppPageHeader.topInset`), not left to the first `sizeThatFits` pass, and the form is capped to what the pane's
  limit (`paneMaxHeight`) leaves below it, so it scrolls with the header in view. Names are looked up without
  icons (`AppIdentities`); an icon loads when its frame meets the scroll view's visible bounds
  (`AppIcon`): a grouped form builds every row, so `onAppear` is not enough, and macOS 14 lacks
  `onScrollVisibilityChange`. Applications is never listed; adding goes through an open panel or
  the running apps.
- **Notices.** `BannerPlan.items` gives them in order: config error, unsaved change, status too
  new, PureMouse off, paused, Input Monitoring (a Bluetooth mouse is waiting), Logi Options+,
  Accessibility on the panes that need it, no mouse (General only; the Mouse panes say it in
  place). The Logi Options+ notice offers Quit Logi Options+ as its only bordered button
  (`LogiOptionsAction.quit`: asks the app to quit through `NSRunningApplication.terminate()`,
  never a signal, and never starts it) and Open Login Items Settings… as a link-style button
  under its caption, in the banner, General's row and the menu. It appears and clears in
  place, as the daemon re-checks (see [How it works](how-it-works.md#permissions)). A pane shows
  only the first, with "N more notices" opening General, whose Status section lists them all as rows
  (off is its PureMouse row). Use Last Working Config… asks before it replaces the file.
- **Labels.** Settings controls carry their own accessibility label where a `RowLabel` (title plus
  caption) leaves them unnamed. A shortcut binding's accessibility value is `Shortcut.spoken`.

## Layout

| Place | Shown by default | Advanced |
|---|---|---|
| General | Status (PureMouse running/paused/off, Start or Stop, active notices), Open at login, Show in menu bar, Low battery notifications (a disabled switch that keeps the choice, with Open Notification Settings…, while macOS has them off), Permissions (status only) | Advanced… sheet: Work with Universal Control, Config file, Log, Reset All Settings… |
| Mouse header | Buttons, Scrolling, Pointer segments; mouse pop-up with two or more mice; Find by Pressing… and the device card on Buttons | — |
| Mouse › Buttons | One row per button with its action | Gesture directions (disclosure, collapsed, caption summarises them; choosing Hold and Move expands it); Other controls (disclosure: named controls and bound ones, see Device card); Advanced… sheet, only while some button anywhere is Hold and Move: gesture Distance and Repeat |
| Mouse › Scrolling | Smooth scrolling, Feel, Speed, Try it (collapsed); Main Wheel: Reverse direction, Wheel mode, SmartShift; Thumb Wheel: Action (Turn left/right when Custom); each when the mouse has it | Advanced… sheet, each row only when it applies: Acceleration, Glide, Hold Shift to scroll sideways (dimmed while smooth scrolling is off); Switches at (while SmartShift is on); thumb wheel Reverse direction (when it scrolls here or in some app), Swap directions and Turn distance (when it has actions), Speed (when it scrolls) |
| Mouse › Pointer | Pointer Speed slider with its value; Presets summary row; both only when the mouse can adjust its speed (else one "Not supported by this mouse." row, unless a value is set) | Exact value (disclosure); Edit Presets… sheet (also opened from the menu) |
| Apps | App list whose rows name the areas each app changes, Add App (bordered pull-down) in the footer, routing note; empty state with an Add App… button that opens the Applications panel | Each app opens as a page (‹ Apps, Buttons \| Scrolling); on it, gesture directions, other controls and more thumb wheel options are disclosures, and the editors are sheets |
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

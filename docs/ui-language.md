# UI language

The words PureMouse shows: in the menu, Settings, alerts, notifications, accessibility labels and
the CLI. The target register is Apple's own (HIG Writing, Apple Style Guide): plain, concise,
calm and approachable, read aloud before it ships. A change to user-facing text follows this page,
and a change to this page lands with the text it changes.

## Rules

- **Capitalisation.** Title Case for menu items, buttons, pop-up and picker entries, segment
  labels, tab and window titles, form section headers and notification actions. Sentence case for
  row labels, switches, captions and body text.
- **Alert and banner titles.** A fragment takes Title Case and no full stop ("Config File Not
  Valid"). A full sentence takes sentence case and its full stop or question mark ("Reset all
  settings?"). Never "Error". The body is complete sentences.
- **Buttons** are a verb that names the result ("Reset All Settings", "Start"). "Cancel" always
  cancels; "OK" only acknowledges an informational alert; "Done" closes a sheet whose changes
  already apply.
- **Ellipsis.** A button or menu item that opens a PureMouse sheet or window, or that needs more
  input before it acts, ends in "…" ("Advanced…", "Edit Presets…", "Find by Pressing…", "Settings…",
  "Reset All Settings…"). One that hands off to another app takes none ("Open System
  Settings", "Open Config File", "Show in Finder"), as in Apple's own prompts.
- **Contractions.** Use them: "isn't", "can't", "couldn't", "don't".
- **Captions** describe the on state and the visible outcome, and stay true whatever the person's
  other settings are (natural scrolling on or off, other apps' settings). Say "Reverses this
  wheel", not "Classic direction while the trackpad stays natural". A caption on a control that
  overlaps System Settings says it applies to this mouse.
- **Verbs mean what happens.** A menu item or button names its effect. If it opens Settings to
  explain something, it names the thing, not an action it doesn't take.
- **Name things by what they do for the person**, and reuse Apple's names for Apple's things.
  One term per concept (Glossary).
- **No jargon.** No "daemon", "agent", "HID++", "status item" or file-system paths in UI text,
  except where the person asked for a path (General › Advanced…, the CLI). "DPI" appears only
  beside a number. Prefer "mouse" to "mice" where a sentence allows.
- **Tone.** No "we", "please", "!", "oops" or blame. "Turn on" and "turn off", never "toggle"; an
  alert is an alert, not an "error message". Say what happened and what to do next.
- **Menu labels** drop articles ("Show Log in Finder"). A label that changes with state keeps a
  verb so it can't read as a state ("Pause PureMouse" / "Resume PureMouse").
- **Segments** are nouns, all text or all symbols.
- **Errors.** Shown next to the problem: what failed, then one sentence on what to do. Raw command
  output and paths go to the log, not the alert. A config error names the bad value and where it
  is ("buttons.back: unknown action “explode”") and never lists the choices.
- **Empty states.** What's missing, then what to do: "No mouse found. Turn on Bluetooth or plug in
  the receiver."
- **Permissions.** Active voice, one specific sentence on what it's for and what stops working
  without it. macOS's own names: "Accessibility", "Input Monitoring", "Privacy & Security".
- **Notifications.** Title: the thing and its state, without the app name ("MX Master 3S battery
  low"). Body: the fact, then what to do ("20% left. Charge it soon."). Actions in Title Case.
- **The update question and reminders.** The question is an alert with a sentence title and its
  question mark ("Check for updates automatically?"), a body that says what is sent and that
  nothing installs by itself, and two buttons that name the result: "Check Automatically" (the
  default) and "Don't Check". The reminder is a quiet notification: title "PureMouse 1.2.3 is
  available", body "Click to read what's new.". The menu row "Update to 1.2.3…" takes an ellipsis
  because an alert follows before anything changes ("Update to PureMouse 1.2.3?", body: what is
  downloaded and checked; buttons "Update and Relaunch" (default) and "Cancel"). Settings › About
  offers the same as an "Update and Relaunch" button (the alert follows), disabled with the line
  "Updating to 1.2.3…" under it while it runs. While it runs the menu row is the disabled
  "Updating to 1.2.3…"; once the app is replaced the row is gone. A refusal is one disabled line in the sentence form
  below, then "View Release" (the release page, for a manual update), "Update to 1.2.3…" again
  where trying again could work, and "Skip This Version". Failure lines name what failed, not
  how: "The download doesn't match its checksum", "The update wasn't signed by the same
  certificate", "The update isn't signed", "The update's files don't match its signature", "The
  update isn't newer than this version", "The update isn't the release that was announced", "The
  update was stopped", "Couldn't download the update"; a copy that can't be
  replaced says "Can't update: this copy needs an administrator" (or "is on a read-only disk").
  After a swap that can't reopen the app: "PureMouse is updated." / "Open it from Applications to
  finish."
- **Tooltips** are under 75 characters and never repeat the control's name.
- **CLI.** Success is a sentence on stdout. A failure is one line on stderr led by `puremouse: `
  ("puremouse: can't register: …") and a non-zero exit status.
- **Key equivalents.** An ⌥ alternate uses one modifier and shares the key equivalent of the item
  it replaces, since AppKit pairs them only then (Hide Menu Bar Icon is ⌥⌘Q under Quit's ⌘Q; the
  status menu has no windows to keep).
- **Spelling.** Australian English in docs and prose. UI text uses macOS's own names for macOS
  places ("Applications folder", "Login Items", "Privacy & Security").
- **Accessibility labels** say what a control does in words; never read a separator ("·") or a
  symbol name aloud, and never give two controls in one window the same label. A shortcut is
  spoken in words ("Shift Command 4", `Shortcut.spoken`), never as its glyphs. The status item's
  label names the mouse's state in order (off; the mouse and its battery, spoken as a percentage
  or, with only a level, "battery low" or "battery critical"; "paused" or "on another Mac"), and
  says paused whether or not a mouse is listed. `PUREMOUSE_DEV_AX_DUMP=1` checks the Settings
  labels (docs/ui-design.md, "Motion, sound and accessibility").

## Glossary

One term per concept. "Retire" lists words that must not appear in UI text for that concept.

| Concept | Use | Retire |
|---|---|---|
| PureMouse's preferences window | Settings (menu item "Settings…"); "settings" lower case in prose ("pointer settings") | Preferences |
| macOS preferences | System Settings; button "Open System Settings" | "Settings" alone for macOS, "Open Settings…" |
| The menu bar presence | menu bar icon; "menu bar app" only for its version and updates | status item |
| The background process | PureMouse: Running, Paused, Off | daemon, agent, "the running PureMouse" |
| The JSON file | config file; button "Open Config File" | "Config" alone, "Settings" for the file |
| Mouse resolution | Pointer Speed (row, menu, action); "DPI" beside a number; caption says it's this mouse's own speed, separate from System Settings › Mouse | Resolution, Tracking (except as System Settings' own name) |
| Saved pointer speeds | presets; "Edit Presets…" (Pointer row, menu; "Add Presets…" in the menu when none), "Add Preset" (sheet "+") | chips, steps, Add Current |
| A value left unset | "Using the mouse's own setting." (caption); "Mouse Default" (picker entry) | "Mouse default." fragment, "Works as Normal", bare "Default" |
| A per-tab reset | Restore Defaults (pane footer; resets everything on that tab, advanced rows included); "Restore Defaults…" when it asks first | Reset |
| Settings moved off the default view | Advanced… (pane footer button, opens a sheet) | More, Fine-tuning, Expert |
| Running now vs at login | Start / Stop change only whether PureMouse runs now; "Open at login" is the separate switch | Start that also turns on login |
| Identify a button by pressing it | Find by Pressing… | Select by Pressing |
| The whole reset | Reset All Settings… | — |
| The last good config | Use Last Working Config… | Restore Last Working |
| App scope | Same as Everywhere (entry), everywhere (prose) | global |
| A value left to a wider scope (an app to everywhere, a mouse to all mice) | the row exactly as in the wider scope: same control, full contrast, its usual help, no caption; a pop-up's first entry "Same as Everywhere (Mission Control)" ("Same as All Mice (…)") removes the own value; VoiceOver adds ", same as All Mice" to the value of every control of the row (a pop-up, switch, segmented control or slider) | Dimmed value, "Same as Everywhere" as a caption, "Everywhere: …" caption |
| A value a mouse or app sets itself | the caption "Set for this mouse." ("Set for this app."), then on the same line a link "Use All Mice Setting" ("Use Everywhere Setting"); the row's help moves to its tooltip, except Feel's "Custom. Adjust in Advanced." when no preset matches; VoiceOver names the row in the link ("Use All Mice Setting for Speed"), and the link's hit target is at least 20 pt | Overridden, Custom value, a mark on inherited rows |
| The one explanation of a mouse's rows | Settings you don't change follow All Mice. (in the mouse pop-up's menu, once) | The same sentence on each pane or row |
| The mouse pop-up and its entries | Mouse (its label); All Mice, then each mouse's name; "Unknown mouse <key>" for an entry no mouse has | Device, Profile, Default mouse |
| Giving a mouse's value back | Use All Mice Setting (the row's link, context menu item and VoiceOver action); the row then looks as it does under All Mice | Reset to default, Inherit |
| The pop-up's Apps note | Apps are the same for every mouse. | Apps are global |
| An app's own speed and glide | Custom scrolling (switch and row summary) | Own scrolling speed, Scrolling speed (summary) |
| An app with nothing set yet | No custom settings (row summary) | "No settings yet, so not saved" |
| One app's settings from the status menu | "Settings for <app name>…" (opens its sheet in Apps) | App Settings…, Configure <app>… |
| Adding an app | Add App (a pull-down menu, so no ellipsis; its "Choose from Applications…" entry opens the panel); the empty state's button, which opens the panel, is Add App… | Add Application, "+" alone |
| Scroll animation | glide (slider), Smooth Scrolling (feature) | smoothing |
| Wheel modes | Ratchet, Free Spin | free-spin, ratchet (lower case in a label) |
| Permission state | Allowed, Not allowed | granted, missing, "Stopped working" |
| Battery | battery low, battery critical; "20% left" | — |
| Thumb wheel steps per action | Turn distance; caption says what it does ("How far to turn before the action repeats.") | Turn per action, "wheel steps" |
| Scroll acceleration | a strength, shown without a unit (Off … Strong) | "1.0×" |
| A shell command bound to a control | Run Command (action and sheet title; "Run Command…" in the picker) | Run Shell Command |
| Capturing a shortcut | Record Shortcut, then "Recording…" while it listens; "Or enter it" for typing | "Click to record" |
| Thumb wheel actions the other way round | Swap directions ("Swaps what turning left and right does."); an app row summary says "directions swapped" or "directions not swapped" | Reverse direction (for actions), Reversed, Normal direction |
| SmartShift threshold | Switches at (Slower … Faster) | Threshold, Sooner/Later |
| A control this mouse lacks, kept because it is set | "Not supported by this mouse." (caption) | — |
| Checking for a new release | Check for Updates (button, on demand); "Check for updates automatically" (switch, About; sentence case); the question "Check for updates automatically?" with Check Automatically / Don't Check | Auto-update, Updater, "Look for updates", Check Now |
| A newer release is known | "Update to 1.2.3…" (menu row; installs after an alert); "Update and Relaunch" (About button, same alert); "Skip This Version" (menu row under it); "View Release" (the page, About and the menu after a refusal); notification "PureMouse 1.2.3 is available" | Upgrade, Install Update, Download, "New version" |
| Support | Support PureMouse (About link); GitHub Sponsors (the destination) | Donate, Buy Me a Coffee, Pro, Free version |

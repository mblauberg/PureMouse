# UI language

The words PureMouse shows: in the menu, Settings, alerts, notifications, accessibility labels and
the CLI. The target register is Apple's own (System Settings, macOS Human Interface Guidelines):
short, plain, calm. A change to user-facing text follows this page, and a change to this page
lands with the text it changes.

## Rules

- **Capitalisation.** Title Case for menu items, buttons, pop-up and picker entries, segmented
  labels, tab and window titles, and alert titles that are commands. Sentence case for row labels,
  captions, toggles, section headers, banner titles and alert titles that are statements.
- **Ellipsis.** Only when the action needs more input before it happens ("Keyboard Shortcut…",
  "Reset All Settings…"). Never on an action that just opens something ("Open System Settings").
- **Verbs mean what happens.** A menu item or button names its effect. If it opens Settings to
  explain something, it names the thing, not an action it does not take.
- **Contractions.** Spell them out: "is not", "cannot", "could not".
- **No jargon.** No "daemon", "agent", "HID++", "status item" or file-system paths in UI text,
  except where the user asked for a path (General › Files, the CLI). "DPI" appears only beside a
  number.
- **No exclamation marks, no "please", no blame.** Say what happened and what to do next.
- **Errors.** Title: what failed, as a statement. Body: one sentence on what to do. Raw command
  output and paths go to the log, not the alert.
- **Spelling.** Australian English in docs and prose. UI text uses macOS's own names for macOS
  places ("Applications folder", "Login Items", "Privacy & Security").
- **Accessibility labels** say what a control does in words; never read a separator ("·") or a
  symbol name aloud, and never give two controls in one window the same label.

## Glossary

One term per concept. "Retire" lists words that must not appear in UI text for that concept.

| Concept | Use | Retire |
|---|---|---|
| PureMouse's preferences window | Settings (menu item "Settings…") | — |
| macOS preferences | System Settings; button "Open System Settings" | "Settings" alone for macOS, "Open Settings…" |
| The menu bar presence | menu bar icon; "menu bar app" only for its version and updates | status item |
| The background process | PureMouse: running, off, paused | daemon, agent, "the running PureMouse" |
| The JSON file | config file; button "Open Config File" | "Config" alone, "Settings" for the file |
| Mouse resolution | Pointer Speed (row, menu, action); "DPI" beside a number | Resolution, Tracking (except as System Settings' own name) |
| Saved pointer speeds | presets | chips, steps |
| A value left unset | "Using the mouse's own setting." (caption); "Mouse Default" (picker entry) | "Mouse default." fragment, "Works as Normal", bare "Default" |
| A per-tab reset | Restore Defaults | Reset |
| The whole reset | Reset All Settings… | — |
| The last good config | Use Last Working Config | Restore Last Working |
| App scope | Same as Everywhere (entry), everywhere (prose) | global |
| Scroll animation | glide (slider), Smooth Scrolling (feature) | smoothing |
| Wheel modes | Ratchet, Free Spin | free-spin, ratchet (lower case in a label) |
| Permission state | Allowed, Not allowed | granted, missing |
| Battery | battery low, battery critical; "20% left" | — |
| Thumb wheel steps per action | Turn distance | Turn per action |

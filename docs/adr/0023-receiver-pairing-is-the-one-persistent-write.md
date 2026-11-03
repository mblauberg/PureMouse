# 23. Receiver pairing is the one persistent write

## Status

Accepted, not built. A protocol spike (Unifying and Bolt, checked against Solaar's documented
behaviour and a real receiver) gates the code: nothing ships until it passes. This amends the
hard rule in `AGENTS.md`, "Nothing may be persisted on the mouse or receiver".

## Context

A Logitech receiver keeps its paired devices in its own memory. Pairing a mouse with a receiver, or
unpairing one, is the only way to change that list, so it is persistent by nature: it survives
power cycles, other computers and the removal of PureMouse. The hard rule exists so that mice and
receivers work normally without PureMouse, and pairing does not break that, since the receiver
keeps working with or without PureMouse. Epic #155 asks for pairing from Settings, so a person
need not run Logi Options+, which PureMouse must never start.

## Decision

PureMouse may pair or unpair a device on a Unifying or Bolt receiver, and nothing else persistent.

- The person starts it in Settings, from the receiver's row, and confirms it in an alert that says
  the receiver keeps its paired devices, even without PureMouse and on other computers.
- It is never stored in the config, never exported or imported, never replayed on reconnect or at
  login, and never offered as an App Intent, an action, a binding or a CLI command.
- Settings never opens HID devices, so the daemon performs it on a request from Settings. Cancel,
  closing the sheet or the receiver's 30 s window ending closes the pairing window.
- Every other write stays banned: persistent diversion, haptic strength, enable flags, onboard
  profiles (0x8100) and configuration. Switching host (Easy-Switch) is a command applied to the
  running mouse, not a stored setting, and is not covered by this exception.

## Alternatives rejected

- Keep the rule absolute: the person would have to install Logi Options+ to pair a mouse, which
  fights PureMouse over the mouse.
- Pair automatically, or from config: a stored or replayed pairing would change a receiver without
  the person present.
- Offer pairing as an App Intent: an unattended Shortcut could unpair a device.

## Consequences

- `AGENTS.md` names the exception and links this record. The Receiver sheet, the alert and the
  recovery tests land with the slice that builds it, with `docs/ui-design.md` and `docs/privacy.md`
  if what is written changes.
- The spike result goes in this record, and the status becomes `Accepted` when the code is in the
  tree. If the spike fails, this record is revised or withdrawn before any code lands.

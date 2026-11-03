# 13. Device drawings as bundled vector PDFs plus Swift hit regions and part outlines

## Status

Accepted, built (#56, #130): the device card on Mouse > Buttons

## Context

Settings should show the mouse, in original art per form factor, loaded only when the pane is
shown, and a part of the drawing should lead to the setting it stands for.

## Decision

Three family templates are drawn, each in a light and a dark SVG compiled to PDF by the existing
`rsvg-convert` step and bundled with the Settings helper (`assets/silhouettes`): the MX Master
shape (`mx`), the MX Anywhere's (`compact-anywhere`) and the Signature M750's (`compact-m750`).
Parts are not drawn into the PDF as markers. Each family has typed Swift data, `DeviceArt.geometry`:
a **hit region** per part (a polygon that partitions the drawing, so a point is in at most one) and
the part's own **outline**, which hover and selection fill. Both are in the art's 100 x 124 units.
The data is generated from the artist's `regions.json` and committed as Swift; the generators stay
out of the repo.

A mouse is matched by its device key, never its name: the nonzero 16-bit product IDs in the key
are compared with each model's IDs (`DeviceArt.models`). Which control a part stands for is per
model (the MX Master 4's thumb rest is its haptic panel, the 3 and 3S's the gesture button). A
mouse with no listed model, and every other form (MX Vertical, Lift, MX Ergo, G series, the 2S),
gets no drawing and no card. The capability map ([ADR 4](0004-device-identity-and-companion-contract.md))
still says which settings apply.

A part opens its setting through the strip's own selection (`MouseSelection.select`), so
unsaved edits, the last-segment memory and the window's fit behave as for a click on the strip.

## Alternatives rejected

- Logitech product renders: licensing and trademark.
- One image per model: unbounded, and the capability map already says what is on each mouse.
- SwiftUI `Path` literals or SF Symbols: no design workflow, or a single shape with no callouts.

## Consequences

- Tiny, tinted correctly in dark mode, and reviewable as SVG.
- Regions and outlines are authored with the art per family, and tests check that cells lie inside
  the body, do not overlap and are at least 20 x 20 pt at the card's scale; a misplaced one shows in
  the screenshot check.
- A new model is its product IDs and part bindings in `DeviceArt.models` (add its IDs with the first
  `puremouse probe` of it); a new shape is a new family and three files.
- `scripts/build-app.sh` copies the PDFs into the helper.

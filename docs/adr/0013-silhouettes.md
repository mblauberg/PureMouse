# 13. Device drawings as bundled vector PDFs plus Swift hit regions and part outlines

## Status

Accepted, built (#56, #130): the device card on Mouse > Buttons

## Context

Settings should show the mouse, in original art per form factor, loaded only when the pane is
shown, and a part of the drawing should lead to the setting it stands for.

## Decision

Four family templates are drawn, each in a light and a dark SVG compiled to PDF by the existing
`rsvg-convert` step and bundled with the Settings helper (`assets/silhouettes`): the MX Master 3
and 3S (`mx`), the MX Master 4 (`mx4`), the MX Anywhere's (`compact-anywhere`) and the Signature
M750's (`compact-m750`). The 4 is the 3S's shape with a small gesture key on the wing, just ahead
of Forward and Back; the same generator draws both.
Parts are not drawn into the PDF as markers. Each family has typed Swift data, `DeviceArt.geometry`:
a **hit region** per part (a polygon that partitions the drawing, so a point is in at most one) and
the part's own **outline**, which hover and selection fill. Both are in the art's 100 x 124 units.
The art and the data come from one source: `assets/silhouettes/source` (Python 3, standard library
only) draws the SVGs and writes `assets/silhouettes/regions.json`, and `scripts/make-silhouettes.sh`
runs it, compiles the PDFs with `rsvg-convert` (as `make-icon.sh` does) and generates
`DeviceArtGeometry.swift` from the regions. The outputs are committed, so building needs neither
tool. A rerun reproduces the SVGs, regions and Swift exactly; only the PDFs differ, by a creation
date.

A mouse is matched by its device key, never its name: the nonzero 16-bit product IDs in the key
are compared with each model's IDs (`DeviceArt.models`). Which control a part stands for is per
model (the MX Master 4's thumb rest is its haptic panel and its gesture button, 0x00C3, is a key of
its own ahead of Forward and Back; the 3 and 3S's gesture button is the thumb rest). A
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

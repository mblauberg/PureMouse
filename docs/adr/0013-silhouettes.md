# 13. Silhouettes as bundled vector PDFs plus a Swift callout table

## Status

Accepted

## Context

Settings should show the mouse with its controls marked, in original line art per form factor,
loaded only when the pane is shown.

## Decision

SVG sources per form factor are compiled to PDFs by the existing `rsvg-convert` step and bundled
with the Settings helper. Callout positions are typed Swift data, keyed by form factor; the
capability map ([ADR 4](0004-device-identity-and-companion-contract.md)) says which callouts apply.

## Alternatives rejected

- Logitech product renders: licensing and trademark.
- One image per model: unbounded, and the capability map already says what is on each mouse.
- SwiftUI `Path` literals or SF Symbols: no design workflow, or a single shape with no callouts.

## Consequences

- Tiny, tinted correctly in dark mode, and reviewable as SVG.
- Callout positions are placed by hand per form factor; a misplaced one shows in the screenshot
  check.
- `scripts/build-app.sh` copies the PDFs into the helper.

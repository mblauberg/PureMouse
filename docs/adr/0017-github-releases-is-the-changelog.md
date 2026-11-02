# 17. GitHub Releases is the changelog

## Status

Accepted

## Context

Release notes already live on GitHub Releases, published releases can be made immutable, and
`gh release create --generate-notes` with categories in `.github/release.yml` drafts them from
pull-request labels.

## Decision

No `CHANGELOG.md`. The README links to Releases. Release notes lead with what users see, and put
anything that affects permissions or needs a step from the user first.

## Alternatives rejected

- A `CHANGELOG.md` in Keep a Changelog style: duplicates the releases and drifts from them.

## Consequences

- History lives only on GitHub; revisit if the project moves elsewhere.
- Pull requests need a label (bug, device, documentation) to land in the right category.

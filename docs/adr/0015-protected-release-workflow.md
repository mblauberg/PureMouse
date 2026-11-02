# 15. Releases are built by a protected GitHub Actions workflow

## Status

Accepted

## Context

A release needed one Mac holding one keychain item, and was zipped and uploaded by hand. The
repository is public, so signing secrets must never be reachable from pull requests.

## Decision

`scripts/release.sh` implements the pipeline, and a maintainer can run it locally. A thin workflow
runs it on `v*` tags in the protected `release` environment (the owner as required reviewer, tags
only), imports the signing p12 into a temporary keychain, attests the disk image and creates a
draft release with the dmg and `SHA256SUMS`. The owner publishes the draft. Actions are pinned to
full SHAs, each job's token has the least permissions it needs, and the workflow has no
pull-request trigger. Pull-request CI runs the same script as a dry run.

## Alternatives rejected

- Local-only releases: no provenance and no approval trail. Kept as the break-glass path, using the
  same script.
- A self-hosted runner: a persistent keychain and a larger attack surface.
- Auto-publishing: removes the owner's second gate.

## Consequences

- Signing material lives in environment secrets, accepted and revocable.
- Two owner approvals per release by design: the environment, then publishing the draft.
- `docs/development.md` lists the repository settings the workflow relies on.

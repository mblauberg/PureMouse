# 14. Signing identity is configuration; hardened runtime always

## Status

Accepted

## Context

Releases were signed by hand with a self-signed `PureMouse` identity that lives in one keychain.
macOS ties every user's Accessibility and Input Monitoring grants to that certificate. A Developer
ID would let Gatekeeper open PureMouse without a Terminal step, but enrolment is the owner's
choice and must never block other work.

## Decision

- The signing identity is an input: locally the first of `PUREMOUSE_SIGN_IDENTITY`, a Developer ID
  Application identity, the self-signed `PureMouse`, then ad hoc (`scripts/lib.zsh`); in the release
  workflow a p12 secret plus its name. Today that is the self-signed identity; later a Developer ID
  certificate in the same secrets, with no code change.
- Every build is signed inside out, without `--deep`, with the hardened runtime, whatever the
  identity (`scripts/sign-bundle.sh`), and checked by `scripts/verify-bundle.sh`. No entitlements
  unless the hardened-runtime spike shows one is needed.
- Notarisation and stapling run only when all notary secrets exist. Some but not all present fails,
  naming the missing ones; none present skips with a log line.
- A Developer ID identity without notary credentials stops the release.
- The bundle identifiers are frozen.

## Alternatives rejected

- Hard-wiring Developer ID: blocks every release on enrolment.
- Shipping un-notarised builds silently once a Developer ID exists: users would meet Gatekeeper
  warnings that a missing secret caused.

## Consequences

- Grants carry across releases signed by the same identity; changing identity is a one-time
  re-grant ([ADR 19](0019-developer-id-and-migration-in-one-release.md)).
- Dev builds sign with `--timestamp=none`; releases ask for a secure timestamp.
- Each new nested bundle is one more entry in `scripts/lib.zsh`'s component list.

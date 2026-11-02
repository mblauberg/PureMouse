# 19. Developer ID and the identity switch in one release

## Status

Proposed. Owner-triggered (Apple Developer Program enrolment) and gated by the SMAppService spike.

## Context

A Developer ID signature makes macOS treat PureMouse as a new client: existing Accessibility and
Input Monitoring grants stop applying, and launch agents registered by 0.3.x no longer start the
new binary. A later move to `SMAppService` ([ADR 18](0018-login-service-seam.md)) would disturb
users a second time. Before 1.0 nothing is engineered for backward compatibility (owner decision,
2026-11-02).

## Decision

Ship a Developer ID signed, notarised and stapled release in which the identity switch and, if the
spike supports it, the move to `SMAppService` arrive together. Upgrading from 0.3.x is a
release-note step, written out once: unregister the old app, then remove the stale PureMouse
entries in System Settings › Privacy & Security and grant the new build. There is no in-app
migration and no permission-reset code.

## Alternatives rejected

- Two releases (identity, then login): two disruptions.
- An in-app migration that removes legacy agents and resets stale grants: code that runs once per
  Mac, for a pre-1.0 app whose users can follow a short release note.

## Consequences

- Upgrading from 0.3.x takes a few manual steps, once.
- Later updates keep the same Team ID and identifiers, so they ask for nothing.

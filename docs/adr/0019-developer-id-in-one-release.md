# 19. Developer ID, the identity switch and the login migration in one release

## Status

Proposed. Owner-triggered (Apple Developer Program enrolment) and gated by the SMAppService spike.

## Context

A Developer ID signature makes macOS treat PureMouse as a new client: existing Accessibility and
Input Monitoring grants stop applying, and launch agents registered by 0.3.x no longer start the
new binary. A later move to `SMAppService` ([ADR 18](0018-login-service-seam.md)) would disturb
users a second time.

## Decision

Ship a Developer ID signed, notarised and stapled dmg in which the identity switch and the login
migration arrive together. On first open the new build removes the legacy agents, registers
through `SMAppService` and, when it detects the identity change, resets its own stale grants once
(its own bundle identifier and the three services only), so macOS prompts afresh. The release notes
say exactly what the user does, once.

## Alternatives rejected

- Two releases (identity, then login): two disruptions.
- Relying on users to toggle stale entries in System Settings: a known false "enabled" state and a
  support burden.

## Consequences

- The migration code runs once per Mac, guarded by a marker file, and is cheap to keep.
- If the spike shows the grant reset needs elevation or is unnecessary, it becomes a banner or a
  documentation change.
- Later updates keep the same Team ID and identifiers, so they ask for nothing.

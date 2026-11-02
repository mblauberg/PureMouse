# Architecture decisions

One file per decision, numbered in the order they were taken. Each has a status: `Accepted`, or
`Proposed` with the spike or owner decision that gates it. A change that implements, amends or
overturns a decision updates its record in the same pull request: consequences learned, spike
results, a status change.

New records follow the same headings: Status, Context, Decision, Alternatives rejected,
Consequences. Keep each to about 40 lines.

| ADR | Status | Decision |
|---|---|---|
| [1](0001-transport-protocol-and-fake-device.md) | Accepted | A transport protocol over IOKit, with a stateful fake HID++ device for tests |
| [2](0002-feature-absence-cache.md) | Accepted | Feature absence is cached per endpoint, and capabilities come from that cache |
| [3](0003-feature-drivers.md) | Accepted | Feature drivers: designed now, built with keyboard support |
| [4](0004-device-identity-and-companion-contract.md) | Accepted | Device identity and an additive companion contract |
| [5](0005-config-v2-device-overrides.md) | Accepted | Config v2 is additive per-device overrides, with no migration |
| [6](0006-ble-input-value-matching.md) | Proposed | Bluetooth HID++ input through vendor-page value matching |
| [7](0007-log-rotation.md) | Accepted | Size-capped log rotation in the daemon |
| [8](0008-primary-buttons-reserved.md) | Accepted | The primary buttons are never bound or diverted |
| [9](0009-settings-helper-app.md) | Accepted | Settings is an on-demand helper app |
| [10](0010-menu-memory-budgets.md) | Proposed | Menu memory policy: measured budgets |
| [11](0011-shared-logic-library.md) | Accepted | A shared logic library and an `AppModel` split |
| [12](0012-multi-device-settings-scopes.md) | Accepted | Multi-device Settings: path-prefix scopes with per-leaf fallback |
| [13](0013-silhouettes.md) | Accepted | Silhouettes as bundled vector PDFs plus a Swift callout table |
| [14](0014-signing-identity-is-configuration.md) | Accepted | Signing identity is configuration; hardened runtime always |
| [15](0015-protected-release-workflow.md) | Accepted | Releases are built by a protected GitHub Actions workflow |
| [16](0016-daemon-owns-its-log.md) | Accepted | The daemon owns its log file |
| [17](0017-github-releases-is-the-changelog.md) | Accepted | GitHub Releases is the changelog |
| [18](0018-login-service-seam.md) | Proposed | Start at login behind a `LoginService` seam |
| [19](0019-developer-id-and-migration-in-one-release.md) | Proposed | Developer ID, the identity switch and the login migration in one release |

# Architecture decisions

One file per decision, numbered in the order they were taken. Each has a status: `Accepted` (the
code is in the tree), `Accepted, not built` (decided, but the code does not exist yet: do not
assume it does), or `Proposed` with the spike or owner decision that gates it. A change that implements, amends or
overturns a decision updates its record in the same pull request: consequences learned, spike
results, a status change.

New records follow the same headings: Status, Context, Decision, Alternatives rejected,
Consequences. Keep each to about 40 lines.

| ADR | Status | Decision |
|---|---|---|
| [1](0001-transport-protocol-and-fake-device.md) | Accepted | A transport protocol over IOKit, with a stateful fake HID++ device for tests |
| [2](0002-feature-absence-cache.md) | Accepted (capability map not built) | Feature absence is cached per endpoint, and capabilities come from that cache |
| [3](0003-feature-drivers.md) | Accepted, not built | Feature drivers: designed now, built with keyboard support |
| [4](0004-device-identity-and-companion-contract.md) | Accepted, not built | Device identity (`m<model>` / `p<pid>`); the status contract is versioned with the bundle |
| [5](0005-config-v2-device-overrides.md) | Accepted, not built | Config v2 is per-device overrides on top-level defaults, with no migration |
| [6](0006-ble-input-value-matching.md) | Proposed | Bluetooth HID++ input through vendor-page value matching |
| [7](0007-log-rotation.md) | Accepted | Size-capped log rotation in the daemon |
| [8](0008-primary-buttons-reserved.md) | Accepted (device scope not built) | The primary buttons are never bound or diverted |
| [9](0009-settings-helper-app.md) | Accepted, not built | Settings is an on-demand helper app |
| [10](0010-menu-memory-budgets.md) | Proposed | Menu memory policy: measured budgets |
| [11](0011-shared-logic-library.md) | Accepted, not built | A shared logic library and an `AppModel` split |
| [12](0012-multi-device-settings-scopes.md) | Accepted, not built | Multi-device Settings: path-prefix scopes with per-leaf fallback |
| [13](0013-silhouettes.md) | Accepted, not built | Silhouettes as bundled vector PDFs plus a Swift callout table |
| [14](0014-signing-identity-is-configuration.md) | Accepted (notarisation not built) | Signing identity is configuration; hardened runtime always |
| [15](0015-protected-release-workflow.md) | Accepted, not built | Releases are built by a protected GitHub Actions workflow |
| [16](0016-daemon-owns-its-log.md) | Accepted | The daemon owns its log file |
| [17](0017-github-releases-is-the-changelog.md) | Accepted | GitHub Releases is the changelog |
| [18](0018-login-service-seam.md) | Proposed | Start at login behind a `LoginService` seam |
| [19](0019-developer-id-in-one-release.md) | Proposed | Developer ID and the identity switch in one release; upgrading from 0.3.x is a release-note step |

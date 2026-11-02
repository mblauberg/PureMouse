# Security

## Supported versions

Only the [latest release](https://github.com/mblauberg/PureMouse/releases/latest) gets security
fixes. Please update before reporting.

## Reporting a vulnerability

Report it privately through GitHub:
[Report a vulnerability](https://github.com/mblauberg/PureMouse/security/advisories/new). Please do
not open a public issue. There is no security email address.

PureMouse is a personal project with one maintainer, so expect an acknowledgement within 7 days;
how soon a fix follows depends on the severity and the change.

## What is in scope

PureMouse runs as you, with no elevated privileges, and has no server. What it can do, and so what
is worth reporting:

- **The background process posts input events.** With Accessibility granted it can send keystrokes,
  clicks and scrolls to any app. A way to make it post events you did not configure is in scope.
- **`run` actions execute commands** from your own config with `/bin/sh`, as you. Anything that lets
  another user or process put a command there, or run one without your config, is in scope. A
  command you wrote yourself doing what you wrote is not.
- **The config and companion files** in your home folder are read and written by PureMouse
  ([Privacy](docs/privacy.md) lists them). Parsing bugs that crash or misbehave on a hostile file
  are in scope.
- **The update check** is one HTTPS GET to the GitHub API, made only when you press
  **Check for Updates**. A way to make it fetch or open anything else is in scope.
- **The signed app and the release process**: a tampered download that still verifies, or a way
  into the release workflow's signing secrets.

Bugs in macOS, Logitech firmware or Logi Options+ belong with their vendors.

## Verifying a download

Each release lists the SHA-256 of its download. Compare it with:

```sh
shasum -a 256 PureMouse-<version>.zip
```

Releases built by the release workflow also carry `SHA256SUMS` and a build attestation. In the
folder holding the download:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify PureMouse-<version>.dmg --repo mblauberg/PureMouse
```

Once releases are notarised, macOS can check the signature as well:

```sh
spctl --assess --type execute --verbose /Applications/PureMouse.app
```

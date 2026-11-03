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
- **The update check** is one HTTPS GET to the GitHub API, made when you press
  **Check for Updates**, or at most once a day if you allowed automatic checks. A way to make it fetch or open anything else is in scope.
- **Installing an update** (**Update to X.Y.Z…**, [ADR 22](docs/adr/0022-update-trust-is-the-signing-requirement.md))
  runs a download, so anything that makes it install what does not satisfy the running app's own
  code-signing requirement, install a version that is not newer, leave the installed app half
  replaced, or ask for a password is in scope.
- **The signed app and the release process**: a tampered download that still verifies, or a way
  into the release workflow's signing secrets.

Bugs in macOS, Logitech firmware or Logi Options+ belong with their vendors.

## Verifying a download

A release is a dmg holding the app, attached to its GitHub release with a `SHA256SUMS` file. Check
the download against it, from the folder holding both:

```sh
shasum -a 256 -c SHA256SUMS
```

If you build PureMouse yourself, `scripts/verify-bundle.sh .build/app/PureMouse.app` checks that
every component is signed, intact, carries the hardened runtime in every architecture and has the
expected identifier and version.

Build attestations and notarisation come with the release workflow
([#46](https://github.com/mblauberg/PureMouse/issues/46)); this page will give their commands
once it exists.

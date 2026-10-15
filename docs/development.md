# Development

Needs Xcode or its command line tools. Design invariants, pitfalls and how to add actions or
device features are in [`AGENTS.md`](../AGENTS.md).

## Build and install

```sh
./scripts/make-cert.sh   # once per Mac: a signing identity, so permissions survive rebuilds
./scripts/install.sh     # build, install /Applications/PureMouse.app and start it
./scripts/uninstall.sh   # stop and remove (keeps your config)
./scripts/package.sh     # release zip for Apple silicon and Intel, in .build/dist/
```

## Test

```sh
swift build && swift test
```

The tests cover pure logic. Anything that touches the mouse needs a live check:

```sh
.build/debug/puremouse probe                                     # read-only; safe with the agent
/Applications/PureMouse.app/Contents/MacOS/puremouse unregister  # stop the installed agent first
.build/debug/puremouse --verbose run ./config.example.json       # then run a dev build
./scripts/install.sh                                             # reinstall and restart the agent
```

Two daemons fight over the mouse, so stop the installed one before running a dev build. A build run
from a terminal uses the terminal's permissions, not the app's.

## Signing

Builds are signed with the code-signing identity named `PureMouse` when the keychain has one
(`PUREMOUSE_SIGN_IDENTITY` picks another). macOS ties permission grants to the signature, so an
ad-hoc build needs them granted again after every install, and every release must be signed with
the same identity. Keep a backup of it.

## Releases

1. Tag `vX.Y.Z` on a clean `main`; the bundle version is the tag without the `v`.
2. Run `./scripts/package.sh` on a Mac that holds the `PureMouse` identity.
3. Attach `.build/dist/PureMouse-X.Y.Z.zip` to a GitHub release with its SHA-256.

CI (`.github/workflows/ci.yml`) builds, tests and bundles ad hoc on pushes to `main` and on pull
requests.

## Icon

The icon is an Icon Composer document, `assets/AppIcon.icon`. After changing it, run
`./scripts/make-icon.sh` (needs Xcode 26+ and `rsvg-convert`) and commit the compiled outputs.
`assets/MenuBarIcon.svg` is the menu bar glyph; keep it in step with the icon. AGENTS.md has the
details.

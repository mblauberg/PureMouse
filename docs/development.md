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

`install.sh` and `package.sh` build through these, which also run on their own:

```sh
./scripts/build-app.sh [--universal] [--version X.Y.Z]   # sign and assemble .build/app/PureMouse.app
./scripts/verify-bundle.sh .build/app/PureMouse.app      # signatures, identifiers, plists
./scripts/check-size.sh .build/app/PureMouse.app         # installed size against the budget
```

`build-app.sh` builds for this Mac only; `--universal` adds Intel and strips local symbols, as
releases do. The bundle version is `--version` or `PUREMOUSE_VERSION` if given, else
`git describe` without the `v` (`0.3.0-2-gabc1234` past a tag); `CFBundleVersion` is the commit
count. Bundle layout, identifiers and the Info.plist writer live in `scripts/lib.zsh`.

## Test

```sh
swift build && swift test
scripts/tests/run.sh        # the build scripts; uses .build/app/PureMouse.app when built
```

`scripts/tests/run.sh <name>` runs only the tests whose names contain `<name>`. The Swift tests
cover pure logic. Anything that touches the mouse needs a live check:

```sh
.build/debug/puremouse probe                                     # read-only; safe with the agent
/Applications/PureMouse.app/Contents/MacOS/puremouse unregister  # stop the installed agent first
.build/debug/puremouse --verbose run ./config.example.json       # then run a dev build
./scripts/install.sh                                             # reinstall and restart the agent
```

Two daemons fight over the mouse, so stop the installed one before running a dev build. A build run
from a terminal uses the terminal's permissions, not the app's.

## Signing

`scripts/sign-bundle.sh` signs every build, the menu app first and then PureMouse.app, each with
its own identifier, without `--deep`, and always with the hardened runtime. The identity is the
first of:

1. `PUREMOUSE_SIGN_IDENTITY`;
2. a valid `Developer ID Application` identity in the keychain;
3. the self-signed identity named `PureMouse` (`scripts/make-cert.sh`);
4. ad hoc (`-`).

Local builds sign with `--timestamp=none`; `sign-bundle.sh --timestamp` asks for a secure
timestamp, which releases need once they are notarised. macOS ties permission grants to the
signature, so an ad-hoc build needs them granted again after every install, and every release must
be signed with the same identity. Keep a backup of it.

`scripts/verify-bundle.sh <app>` checks each component: Info.plist present and valid, identifier
and version as expected, `codesign --verify --strict` passing and the runtime flag set.
`--release` also requires a release version (`X.Y.Z` or `X.Y.Z-rc.N`) and, when
`PUREMOUSE_TEAM_ID` is set (or `scripts/release.env` sets it), a Developer ID Application
signature from that team.

## Releases

1. Tag `vX.Y.Z` on a clean `main`; the bundle version is the tag without the `v`.
2. Run `./scripts/package.sh` on a Mac that holds the `PureMouse` identity.
3. Attach `.build/dist/PureMouse-X.Y.Z.zip` to a GitHub release with its SHA-256.

Release notes come from GitHub Releases ([ADR 17](adr/0017-github-releases-is-the-changelog.md)):
`.github/release.yml` groups merged pull requests by label (bug, device, documentation).

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests: build, `swift test`, the
universal bundle signed ad hoc, `verify-bundle.sh`, `check-size.sh`, the script tests, and the
zipped bundle uploaded as an artefact kept for 7 days. A newer push to a pull request cancels its
running checks.

- The job named `test` is the check the `main` ruleset requires; rename it only together with the
  ruleset.
- The token is read-only (`permissions: contents: read` on the job, nothing at the top level), and
  checkout keeps no credentials.
- Every action is pinned to a full commit SHA with its version in a comment. Dependabot
  (`.github/dependabot.yml`) proposes updates weekly. Look up a pin with
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`, and dereference an annotated tag to its commit.
- The installed-size budget is `INSTALLED_MAX_BYTES` in `scripts/size-budget.env`, measured from
  the universal build plus 15%. Raising it is a reviewed change that says what grew.

## Repository settings the release relies on

Only the owner changes these, and none needs a Developer ID. Check them with the commands shown.

- Private vulnerability reporting, which `SECURITY.md` links to
  (`gh api repos/mblauberg/PureMouse/private-vulnerability-reporting --jq .enabled`).
- Actions pinned to full SHAs, enforced
  (`gh api repos/mblauberg/PureMouse/actions/permissions --jq .sha_pinning_required`).
- A `main` ruleset requiring the `test` check, and a `v*` tag ruleset that lets only the owner
  create release tags.
- A `release` environment that requires the owner's review and accepts only `v*` tags. Its signing
  secrets arrive with the release workflow ([ADR 15](adr/0015-protected-release-workflow.md)).
- Discussions, for questions; the issue chooser links to it.

## Icon

The icon is an Icon Composer document, `assets/AppIcon.icon`. After changing it, run
`./scripts/make-icon.sh` (needs Xcode 26+ and `rsvg-convert`) and commit the compiled outputs.
`assets/MenuBarIcon.svg` is the menu bar glyph; keep it in step with the icon. AGENTS.md has the
details.

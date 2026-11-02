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

`install.sh` and `package.sh` build with `build-app.sh`; CI runs all three, and so can you:

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

## Footprint rig

`scripts/measure-menu.sh` reproduces the menu bar app's memory footprint and says pass or fail
against `scripts/measure-menu.budgets`. Run it on a spare Mac that is logged in to a desktop and
that nobody is using, not on the Mac whose PureMouse you rely on: it opens menus and windows.

```sh
./scripts/measure-menu.sh                 # builds, runs 5 times, prints a table, writes a TSV
./scripts/measure-menu.sh --runs 3 --no-build
./scripts/measure-menu.sh --blocks        # also: 30 menu opens under MallocStackLogging, heap and malloc_history
./scripts/measure-menu.sh --env MallocSpaceEfficient=1   # the same, with a variable in the menu's environment
./scripts/measure-menu.sh --write-budgets # replace the budgets with the medians plus 2 MB, rounded up
```

A Mac with only the command line tools cannot build the menu: the macOS 27 SDK expands SwiftUI's
`@State` with a plugin that ships with Xcode only. Copy Xcode's `libSwiftUIMacros.dylib`
(`Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/`,
the same Swift release as the Mac's own) into a directory of its own there and pass it with
`--plugin-path DIR` (or `PUREMOUSE_RIG_PLUGIN_PATH`).

It exits 0 when every budget holds, 1 when a median exceeds its budget (the line names the
scenario and both numbers) and 2 when the rig itself fails. Samples are in
`.build/rig/results/measure-menu-<time>.tsv` (`--tsv` picks another path).

The rig is isolated from the installed app. It builds the release menu with `-DDEVHOOKS` into
`.build/rig`, wraps it in a bundle of its own (`io.github.mblauberg.puremouse.menu.rig`) and starts
it against a throwaway companion directory (`PUREMOUSE_COMPANION_DIR`, `PUREMOUSE_CONFIG` and
`PUREMOUSE_DAEMON` set), with a sleeping process standing in for the daemon and a one-mouse
`status.json`. A companion directory also renames the doorbells (a short hash of it is appended,
see `docs/companion.md`), so nothing the rig rings reaches the installed app. It only reads the
installed agents' pids with `launchctl print`, before and after, and stops with status 2 if either
changed.

`DevHooks.swift` compiles into a release build only with `-DDEVHOOKS`
(`nm .build/release/PureMouseMenu | grep -c DevHooks` prints 0 without it; with it, check
`strings` for `puremouse.rig`). The rig's part, `Rig`, acts only when `PUREMOUSE_COMPANION_DIR` is
set. The script writes `rig-command` ("number verb") in that directory and rings the rig doorbell;
the menu answers with the number in `rig-ack` once done. Verbs: `menu` (open the menu, close it
again), `settings` and `settings-close` (the Settings window), `relief` (`malloc_zone_pressure_relief`).

Scenarios, each a median of the runs, in MB of physical footprint (`footprint`):

| Scenario | What it measures |
|---|---|
| `fresh` | a new menu app, three seconds after launch |
| `open-1`, `open-3`, `open-10` | after that many opens of the menu |
| `doorbells-200` | a new menu app after 200 status doorbells, each with a changed `status.json` |
| `settings-open`, `settings-closed` | Settings in the menu app's own process, and after it closes (a reading after `malloc_zone_pressure_relief`); informational, no budget |
| `helper-open`, `helper-closed`, `helper-cold-start` | the Settings helper: the menu app's footprint while it is open and after, and the time (ms) from the open request to the helper's first visible window. They read "helper not built" until `PureMouseSettings` is in `Package.swift`. The helper writes a `settings-visible` file in the companion directory when its first window is visible; the cold start is that file's modification time minus the request. |

`scripts/measure-menu.budgets` holds `scenario<TAB>MB` limits; a scenario with no line has none.
Set them from a run of the build you accept (median plus 2 MB, rounded up) and lower them when a
change earns it. Only a Mac with a desktop session can run the rig, so CI does not; repeat it on the
spare Mac after each macOS release (and see `docs/companion.md`, "Footprint", for the figures).

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
and version as expected, `codesign --verify --strict` passing, and every architecture of its
executable signed with that identifier and the runtime flag.
`--release` also requires a release version (`X.Y.Z` or `X.Y.Z-rc.N`) and, when
`PUREMOUSE_TEAM_ID` is set (or `scripts/release.env` sets it), a Developer ID Application
signature from that team.

## Releases

1. Tag `vX.Y.Z` on a clean `main`; the bundle version is the tag without the `v`.
2. Run `PUREMOUSE_SIGN_IDENTITY=PureMouse ./scripts/package.sh` on a Mac that holds the
   `PureMouse` identity. Naming it matters: on a Mac that also holds a Developer ID, the build would
   otherwise sign with that, and every user would have to grant permissions again.
   `package.sh` runs `verify-bundle.sh --release` and makes the zip only if it passes.
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

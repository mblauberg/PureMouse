# Development

Needs Xcode or its command line tools. Design invariants, pitfalls and how to add actions or
device features are in [`AGENTS.md`](../AGENTS.md).

## Build and install

```sh
./scripts/make-cert.sh   # once per Mac: a signing identity, so permissions survive rebuilds
./scripts/install.sh     # build, install /Applications/PureMouse.app and start it
./scripts/uninstall.sh   # stop and remove (keeps your config)
./scripts/release.sh --dry-run --version 0.0.0-ci.local   # universal dmg and SHA256SUMS in .build/dist/
```

`install.sh` and `release.sh` build with `build-app.sh`; `release.sh` also runs these, and so can you:

```sh
./scripts/build-app.sh [--universal] [--version X.Y.Z] [--timestamp]   # sign and assemble .build/app/PureMouse.app
./scripts/verify-bundle.sh .build/app/PureMouse.app      # signatures, identifiers, plists
./scripts/check-size.sh .build/app/PureMouse.app         # installed size against the budget
./scripts/make-dmg.sh .build/app/PureMouse.app out.dmg   # the release dmg alone
```

`install.sh` and `uninstall.sh` take their labels and bundle paths from `scripts/lib.zsh`, stop the
agents with its `stop_agents`, and check the staged app with `verify-bundle.sh` before swapping it
in. `PUREMOUSE_INSTALL_DIR` (default `/Applications`) exists for `scripts/tests`, which run them
against a temporary directory, a stubbed build and a fake `launchctl`.

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
./scripts/measure-menu.sh --env NAME=value   # the same, with one more variable in the menu's environment
./scripts/measure-menu.sh --write-budgets # replace the budgets from the medians (MB plus 2, ms plus half)
```

A Mac with only the command line tools cannot build the Settings helper: the macOS 27 SDK expands SwiftUI's
`@State` with a plugin that ships with Xcode only. Copy Xcode's `libSwiftUIMacros.dylib`
(`Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/`,
the same Swift release as the Mac's own) into a directory of its own there and pass it with
`--plugin-path DIR` (or `PUREMOUSE_RIG_PLUGIN_PATH`).

It exits 0 when every budget holds, 1 when a median exceeds its budget (the line names the
scenario and both numbers) and 2 when the rig itself fails. Samples are in
`.build/rig/results/measure-menu-<time>.tsv` (`--tsv` picks another path), one row per sample with
a `unit` column (MB, or ms for a cold start). `--blocks` exits 2 if `heap` fails or lists no blocks.
A budgets file without a whole-number limit for `fresh`, `open-1`, `open-10`, `doorbells-200`,
`helper-closed`, `helper-closed-5`, `helper` and `helper-cold-start` is also exit 2. `scripts/measure-bare-appkit.sh` measures the bare AppKit comparison.

The rig is isolated from the installed app. It builds the release menu and Settings helper with
`-DDEVHOOKS` into `.build/rig`, wraps each, with the functions that assemble the shipped ones
(`make_menu_bundle` and `make_settings_bundle` in `scripts/lib.zsh`), in a bundle of its own
(`io.github.mblauberg.puremouse.menu.rig`, `….settings.rig`) and starts the menu against a
throwaway companion directory (`PUREMOUSE_COMPANION_DIR`, `PUREMOUSE_CONFIG` and
`PUREMOUSE_DAEMON` set, and `PUREMOUSE_SETTINGS` naming the rig's helper, which the menu opens
with those variables through LaunchServices, as it opens the shipped one), with a sleeping process standing in for the daemon and a one-mouse
`status.json`. A companion directory also renames the doorbells (a short hash of it is appended,
see `docs/companion.md`), so nothing the rig rings reaches the installed app. It only reads the
installed agents' pids with `launchctl print`, before and after, and stops with status 2 if either
changed.

`DevHooks.swift` compiles into a release build only with `-DDEVHOOKS`
(`strings .build/release/PureMouseMenu | grep -c puremouse.rig` prints 0 without it and 1 with it;
`nm` is no use, since the optimiser inlines the type away). The rig's part, `Rig`, acts only when `PUREMOUSE_COMPANION_DIR` is
set. The script writes `rig-command` ("number verb") in that directory and rings the rig doorbell;
the menu answers with the number in `rig-ack` once done. Verbs: `menu` (open the menu, close it
again), `settings` (open the Settings helper) and `settings-close` (quit it). The helper's part,
built with `-DDEVHOOKS` too, writes its pid to `settings-visible` in that directory once its window
is first on screen. After each quit the script waits until `lsappinfo` no longer lists the helper:
LaunchServices keeps a quit app listed for a moment after its process exits, and an open in that
moment brings the dead copy forward and starts none.

Scenarios, each a median of the runs, in MB of physical footprint (`footprint`), or ms:

| Scenario | What it measures |
|---|---|
| `fresh` | a new menu app, about 4.5 s after it reports ready (a 3 s wait, then the 1.5 s settle) |
| `open-1`, `open-3`, `open-10` | after that many opens of the menu |
| `doorbells-200` | a new menu app after 200 status doorbells, 10 ms apart, each after a change to `status.json` (back-to-back posts can coalesce) |
| `helper-cold-start` | ms from the menu being asked for Settings to the helper's window on screen, the helper not running: `settings-visible`'s modification time minus the request's |
| `helper` | the Settings helper's own footprint, 2 s after its window is on screen |
| `helper-open`, `helper-closed` | the menu app's footprint while the helper is open (informational), and 1.5 s after it quits |
| `helper-closed-5` | the menu app's footprint after five opens and quits of the helper |

`scripts/measure-menu.budgets` holds `scenario<TAB>limit` lines in the scenario's unit; a scenario
with no line has none. Set them from a run of the build you accept (`--write-budgets`: a
footprint's median plus 2 MB, rounded up; the cold start's plus half, rounded up to 100 ms) and
lower them when a change earns it. Only a Mac with a desktop session can run the rig, so CI does not; repeat it on the
spare Mac after each macOS release (and see `docs/companion.md`, "Footprint", for the figures).

## Signing

`scripts/sign-bundle.sh` signs every build inside out, the nested apps (the menu bar app, then the
Settings helper) first and PureMouse.app last, each with its own identifier, without `--deep`, and
always with the hardened runtime. The identity is the first of:

1. `PUREMOUSE_SIGN_IDENTITY`;
2. a valid `Developer ID Application` identity in the keychain;
3. the self-signed identity named `PureMouse` (`scripts/make-cert.sh`);
4. ad hoc (`-`).

Local builds sign with `--timestamp=none`; `build-app.sh --timestamp` (and `sign-bundle.sh
--timestamp`) asks for a secure timestamp, which `release.sh` does for a release (it needs the
network, and notarisation needs it). macOS ties permission grants to the signature, so an ad-hoc build needs them granted again after every install, and every release must
be signed with the same identity. Keep a backup of it.

`scripts/verify-bundle.sh <app>` checks each component: Info.plist present and valid, identifier
and version as expected, `codesign --verify --strict` passing, and every architecture of its
executable signed with that identifier and the runtime flag.
`--release` also requires a release version (`X.Y.Z` or `X.Y.Z-rc.N`) and, when
`PUREMOUSE_TEAM_ID` is set (or `scripts/release.env` sets it), a Developer ID Application
signature from that team.

## Releases

1. Tag `vX.Y.Z` (or `vX.Y.Z-rc.N`) on a clean `main`; the bundle version is the tag without the `v`.
2. Run `PUREMOUSE_SIGN_IDENTITY=PureMouse ./scripts/release.sh` on a Mac that holds the
   `PureMouse` identity. Naming it matters: on a Mac that also holds a Developer ID, the build would
   otherwise sign with that, and every user would have to grant permissions again.
3. Attach `.build/dist/PureMouse-X.Y.Z.dmg` and `.build/dist/SHA256SUMS` to a GitHub release.
   `shasum -a 256 -c SHA256SUMS` checks the download.

`release.sh` takes no version: it refuses unless `HEAD` is tagged exactly `vX.Y.Z` or `vX.Y.Z-rc.N`
(one such tag) on a clean tree, and rejects `--version` without `--dry-run`. It builds the universal
app signed once, with a secure timestamp, runs `verify-bundle.sh --release`, checks the size budgets
(`INSTALLED_MAX_BYTES`, `DMG_MAX_BYTES`), makes and signs the dmg (`make-dmg.sh`: ULFO, with
`PureMouse.app` and an `Applications` link), mounts it read-only to verify its contents, and writes
`SHA256SUMS`. `scripts/release.env` holds `PUREMOUSE_TEAM_ID`, empty until there is a Developer ID.

`--dry-run` is the same without the timestamp or notarisation, from any tree:
`--dry-run --version 0.0.0-ci.<shortsha>` (only that form), or `--dry-run` alone on a tagged commit.
CI runs it on every pull request.

### Notarisation

Notarisation follows [ADR 14](adr/0014-signing-identity-is-configuration.md). It runs only when
`NOTARY_KEY_PATH` (an App Store Connect API key file), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` are
all set: it zips and submits the app, staples the app, builds and signs the dmg, then submits and
staples the dmg. With none set, `release.sh` logs "skipping notarisation" and carries on. With some
but not all, it fails naming the missing ones, and a Developer ID signature without them fails too.
On any result but `Accepted` (`Invalid` included) it prints `notarytool log`. This path has only run against a fake `xcrun`
(`scripts/tests/test_release.zsh`); its first real run belongs to the Developer ID work.

Release notes come from GitHub Releases ([ADR 17](adr/0017-github-releases-is-the-changelog.md)):
`.github/release.yml` groups merged pull requests by label (bug, device, documentation).

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests: build, `swift test`, the
`release.sh --dry-run` (the universal bundle signed ad hoc, `verify-bundle.sh`, `check-size.sh` on
the app and the dmg), the script tests, and the dmg and `SHA256SUMS` uploaded as an artefact kept for
7 days. A newer push to a pull request cancels its
running checks.

- The job named `test` is the check the `main` ruleset requires; rename it only together with the
  ruleset.
- The token is read-only (`permissions: contents: read` on the job, nothing at the top level), and
  checkout keeps no credentials.
- Every action is pinned to a full commit SHA with its version in a comment. Dependabot
  (`.github/dependabot.yml`) proposes updates weekly. Look up a pin with
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`, and dereference an annotated tag to its commit.
- The size budgets are `INSTALLED_MAX_BYTES` (the app) and `DMG_MAX_BYTES` (the dmg) in
  `scripts/size-budget.env`, each measured from the universal build plus 15%. Raising one is a
  reviewed change that says what grew.

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

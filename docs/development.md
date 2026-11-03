# Development

Needs Xcode with macOS SDK 26 or later (including the SwiftUI macro plugin used by Settings).
The rules the code keeps are in [How it works](how-it-works.md#invariants);
[Extending](#extending) lists what a new button, action, feature or config section touches.

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
./scripts/verify-bundle.sh .build/app/PureMouse.app      # signatures, identifiers, plists, SDK and minimum
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

App builds explicitly use SwiftPM's `--build-system native` and the selected macOS SDK
(`xcrun --sdk macosx --show-sdk-path`), with a deployment triple of macOS 14.0 for each slice.
This records the actual SDK in `LC_BUILD_VERSION` so macOS 26+ uses the current system design,
while keeping macOS 14 as the minimum. Swift Build currently records the deployment target as
the SDK; do not remove the backend choice without checking every slice with `vtool -show-build`
([ADR 0020](adr/0020-linked-sdk-and-deployment-target.md)). The native backend is deprecated in
Swift 6.4 but still supported; revisit when Swift Build records the correct SDK.

`verify-bundle.sh` rejects a recorded SDK below 26 or a `minos` other than `lib.zsh`'s `minimum`,
for every architecture of every component. Signing and size budgets apply as before. CI checks
the selected Xcode SDK before building on macOS 26, including the release dry run. A separate
macOS 15 job (the oldest hosted image now available) builds and verifies the universal app and
launches its daemon with `--help`; a macOS 14 launch and Settings appearance still need a spare
Mac. No new API availability follows from the SDK stamp alone.

## Test

```sh
swift build && swift test
scripts/tests/run.sh        # the build scripts; uses .build/app/PureMouse.app when built
```

`scripts/test-update-install.sh --dir <new folder>` proves the update install with real code
signatures (ADR 22): two throwaway identities in a temporary keychain, a signed fixture release,
and each bad release refused with the installed app untouched: a bad checksum, another certificate
(for the app, and for the disk image alone), unsigned, modified after signing, not newer, not the
announced release, a swap that fails after committing (immutable flag, deny-delete ACL), a swap that
fails with a damaged old app in place, a preserved copy kept while the installed app is damaged, a
killed run's leftovers, hard links, quarantine and the temporary folder. It first checks that `--dir` is a
new folder whose real parent is not a system path. If it is interrupted and leaves its temporary
keychain in the search list, restore it with the command in the script's header
(`security list-keychains -d user -s ~/Library/Keychains/login.keychain-db`). It builds, signs and mounts images, so
run it on a spare Mac (the workshop), not in CI; it never touches `/Applications` or the real login
agents.

## Measuring input cost

`scripts/measure-input.sh [seconds]` measures the daemon in still and moving windows (default 20
seconds). Keep one `puremouse` daemon running. The script checks that exactly one process exists,
confirms `top` reports PID, CPU, idle wakeups and execution time, then prompts before each window.
For a useful comparison, leave the mouse still for the first prompt and move it normally for the
second. It prints the PID, requested duration, measured sample count, mean idle wakeups per second,
mean CPU percentage and CPU milliseconds for each window. The first three `top` samples are
discarded as warm-up; the first has no prior sample for its CPU percentage, and the next two let the
sampler establish a stable counter baseline.

```sh
scripts/measure-input.sh       # 20 seconds per window
scripts/measure-input.sh 5
scripts/tests/run.sh measure_input
```

Attach owner-collected Bluetooth and receiver still/moving results to issue #33 with the macOS
version and build identifier. Those hardware baselines remain pending until collected.

`scripts/tests/run.sh <name>` runs only the tests whose names contain `<name>`. The Swift tests
cover pure logic. Device behaviour is tested against `HIDPPTesting` fakes (`FakeDevice`,
`FakeTransport`) built from `puremouse probe` dumps in `Tests/Fixtures/probe`, so the probe's
output format is a fixture contract. Anything that touches the mouse needs a live check:

```sh
.build/debug/puremouse probe                                     # read-only; safe with the agent
/Applications/PureMouse.app/Contents/MacOS/puremouse unregister  # stop the installed agent first
.build/debug/puremouse --verbose run ./config.example.json       # then run a dev build
./scripts/install.sh                                             # reinstall and restart the agent
```

The probe uses its own HID++ software IDs, so it is safe beside the daemon. Two daemons fight over
the mouse, so stop the installed one before running a dev build, and run it against a copy of the
config, never the live one. A build run from a terminal uses the terminal's permissions, not the
app's, and never restarts itself; `puremouse permissions` likewise answers for whoever launches
it. `install.sh` rebuilds, re-signs and restarts the agent; check `~/Library/Logs/PureMouse.log`
afterwards. A dev run whose stderr is piped or redirected writes to that log too, since the daemon
attaches any non-terminal stderr to it ([ADR 16](adr/0016-daemon-owns-its-log.md)).

## Menu bar app and Settings from a build

Run `.build/debug/PureMouseMenu` or `.build/debug/PureMouseSettings` beside the installed agent, but
point it away from the real files first. Without these it edits the live config and drives the
installed agent:

| Variable | Points at |
|---|---|
| `PUREMOUSE_CONFIG` | The config file |
| `PUREMOUSE_DAEMON` | The binary it runs for register, stop and the menu commands; a stub script is fine |
| `PUREMOUSE_COMPANION_DIR` | The status and control channel; a fixture `status.json` there stands in for the daemon |

The menu opens the helper it finds by `SettingsLookup` (`PUREMOUSE_SETTINGS`, the nested app, then
the sibling `PureMouseSettings` binary) and passes it the `PUREMOUSE_*` variables.
`PUREMOUSE_COMPANION_DIR` also gives the doorbells names of their own (`Companion.doorbell`,
[companion.md](companion.md#channel)), so such a build neither hears nor rings the installed
daemon's. `PureMouseMenu --login` starts the menu as launchd does, without opening Settings.

### Dev hooks

Debug builds read `PUREMOUSE_DEV_*` variables so that panes, sheets and the menu open without a
click. The doc comments on `DevHooks` in
[`Sources/PureMouseMenu/DevHooks.swift`](../Sources/PureMouseMenu/DevHooks.swift) and
[`Sources/PureMouseSettingsUI/DevHooks.swift`](../Sources/PureMouseSettingsUI/DevHooks.swift) are
the full list. The ones used most:

| Variable | Effect |
|---|---|
| `PUREMOUSE_DEV_APPEARANCE=light\|dark` | Overrides the appearance (menu and helper) |
| `PUREMOUSE_DEV_HIDDEN=1` | The menu app runs as if Show in menu bar were off: resident, no status item (`Locations.showsInMenuBar`) |
| `PUREMOUSE_DEV_MENU=1` | Opens the status menu over a plain backdrop, since its glass shows whatever is behind it, without Settings or the updates question beside it; `PUREMOUSE_DEV_MENU_OPTION=1` builds it as if ⌥ were held, its alternates standing in for the items they replace |
| `PUREMOUSE_DEV_MICE=2` | The menu shows two mice online (a fixture, over whatever the daemon reports), so Pointer Speed has two sections; its preset rows and Edit Presets… do nothing, so they can never write `devices.mb034…` into a live config |
| `PUREMOUSE_DEV_SUBMENU=pointer` | The menu shows Pointer Speed's rows as the menu itself, to capture the submenu without hovering (with `PUREMOUSE_DEV_MENU=1`, and `PUREMOUSE_DEV_MICE=2` for the sections) |
| `PUREMOUSE_DEV_ICON=<directory>` | Writes the menu bar icon's running, paused, off, attention and paused-attention states as `<state>@1x.png` and `<state>@2x.png` and exits, before reading a config or a status (`DevHooks.writeIcons`) |
| `PUREMOUSE_DEV_PANE=<pane>` | Opens a tab (`general`, `mouse`, `apps`, `about`) or a Mouse segment (`buttons`, `scrolling`, `pointer`) |
| `PUREMOUSE_DEV_PICKER=<button>` | A button's action picker on Mouse › Buttons only; `<button>.doubleClick` or `<button>.hold` opens that child row's picker, expanding the row |
| `PUREMOUSE_DEV_EXPAND=<button>` | Expands a button's Double-click and Hold rows on Mouse › Buttons, or on the app's page with `PUREMOUSE_DEV_APP` |
| `PUREMOUSE_DEV_SHORTCUT=<button>` | A button's shortcut sheet on Mouse › Buttons; with `PUREMOUSE_DEV_APP`, that button's shortcut editor sheet over the app's page (`AppPage.body`) |
| `PUREMOUSE_DEV_SHORTCUT_TEXT=1` | With `PUREMOUSE_DEV_SHORTCUT`, opens the shortcut sheet with its "Enter as Text…" text field already shown (`ShortcutSheet`) |
| `PUREMOUSE_DEV_MOUSE=<device key>\|all` | Chooses that mouse on Mouse, or All Mice; `PUREMOUSE_DEV_OTHERS=1` opens Buttons' Other controls; `PUREMOUSE_DEV_MORE=1` opens an app page's More thumb wheel options |
| `PUREMOUSE_DEV_APP=<bundle id>` | Opens Apps on that app's page, adding it without writing; `PUREMOUSE_DEV_APP_SEGMENT=buttons\|scrolling` picks the segment |
| `PUREMOUSE_DEV_THEN_APP=<bundle id>` | After `PUREMOUSE_DEV_THEN_DELAY` seconds (default 1), asks for that app's page, as the menu's "Settings for <app>…" does with another page open |
| `PUREMOUSE_DEV_KEY=esc\|cmd-[` | After `PUREMOUSE_DEV_KEY_DELAY` seconds (default 1.5), sends that key to the window, to test Esc and ⌘[ on an app's page |
| `PUREMOUSE_DEV_SHEET=<name>` | A sheet: `presets` on Mouse › Pointer (`presets-editing`: the same with its first row focused, nothing written), `advanced` on the pane shown, or `aboutMouse` on General (`DevSheet`) |
| `PUREMOUSE_DEV_CAPTURE=<file.png>` | Saves the helper's own windows to that file and quits (`DevCapture`); with `PUREMOUSE_DEV_MENU`, the menu app's open menu. Needs no Screen Recording permission, so it works over SSH |
| `PUREMOUSE_DEV_HOVER=<part>`, `PUREMOUSE_DEV_BUTTON=<button>`, `PUREMOUSE_DEV_FOUND=<button>` | Show the device card's hovered, selected and found-row states on Buttons (`middle`, `top`, `forward`, `back`, `thumbWheel`, `thumbRest`) |
| `PUREMOUSE_DEV_ARRIVAL=thumbWheel\|mainWheel` | On Scrolling, arrives as the device card's part would; `PUREMOUSE_DEV_ARRIVAL_HOLD=1` keeps the outline |
| `PUREMOUSE_DEV_AX_DUMP=1` | Prints each control's accessibility role, label and size for every tab and Mouse segment (with `PUREMOUSE_DEV_PANE`, for what the sheet, picker and shortcut hooks open), and exits 1 on an unlabelled or duplicate control or one under 20 × 20 pt (`DevAXDump`). Run it on the spare Mac, not the one in use |

Config fixtures for these live in `scripts/fixtures`, for `PUREMOUSE_CONFIG` (copy one first: Settings
writes to it). `buttons-triggers.json` gives Forward a click, a double-click (Mission Control) and a
hold (Precise Pointer), the top button Drag Lock, the wheel press Precise Pointer, Safari its own Forward double-click with the hold
switched off, and sets `holdMs` and `doubleClickMs` (500, so the caption reads 0.5 s);
`buttons-click-only.json` is the same buttons with only their clicks. For the Buttons captures and
AX dump of [#158](https://github.com/mblauberg/PureMouse/issues/158), on the spare Mac:

```sh
cp scripts/fixtures/buttons-triggers.json "$TMPDIR/triggers.json"
PUREMOUSE_CONFIG="$TMPDIR/triggers.json" PUREMOUSE_DEV_PANE=buttons PUREMOUSE_DEV_EXPAND=forward \
  PUREMOUSE_DEV_APPEARANCE=dark PUREMOUSE_DEV_CAPTURE="$TMPDIR/triggers-dark.png" .build/debug/PureMouseSettings
PUREMOUSE_CONFIG="$TMPDIR/triggers.json" PUREMOUSE_DEV_PANE=buttons PUREMOUSE_DEV_PICKER=forward \
  PUREMOUSE_DEV_AX_DUMP=1 .build/debug/PureMouseSettings
```

`PUREMOUSE_DEV_PICKER=middle` shows More Ways to Press dimmed with "Remove Hold first.", since the
wheel press's click is Precise Pointer. For the idle cost of triggers, run the daemon on one fixture and
then the other and compare `scripts/measure-input.sh` (above); the trigger run should show no extra
idle CPU or wakeups.

A release build carries none of this; with `-DDEVHOOKS` it carries only the rig's part
([Footprint rig](#footprint-rig)).

### Screenshots

Take captures and README screenshots on a macOS 27 host from a build linked against the macOS 27
SDK ([UI design](ui-design.md#motion-sound-and-accessibility)). `PUREMOUSE_DEV_CAPTURE` covers
Settings. For the menu, `PUREMOUSE_DEV_MENU=1` opens it; a window capture (`screencapture -l`)
leaves out the menu's blur, so the README's menu shots take the shape and shadow from a window
capture and the body from a screen capture of the same rect.

### UI matrix

`scripts/ui-matrix.sh` is the repeatable run of the accessibility dump and the captures. It runs
`PUREMOUSE_DEV_AX_DUMP=1`, and the light and dark `PUREMOUSE_DEV_CAPTURE`, over every pane, sheet and
dev hook in its matrix table (one row each, at the top of the script), against five fixtures: one
mouse, two mice, no mouse, paused and off. It needs a debug build of the helper (`swift build`, then
`.build/debug/PureMouseSettings` or `--binary`) and builds nothing itself.

```sh
scripts/ui-matrix.sh [--out DIR] [--only NAME] [--binary PATH] [--timeout SECONDS]
```

- It writes `summary.txt` into `--out` (a new or empty folder; by default a timed folder under
  `$TMPDIR`), one line per run with its result. The dumps, captures and logs sit beside it.
- `--only` takes a row or a fixture by name. `--timeout` (default 120) kills a run that hangs and
  reports it.
- Exit 1 if a dump reports a finding, a run hangs or fails, or a capture (or a sheet's `-sheet.png`)
  is missing. Exit 2 for a usage error or the config guard.
- Every run is sandboxed. Before anything runs, `HOME`, `CFFIXED_USER_HOME`, `PUREMOUSE_CONFIG`,
  `PUREMOUSE_DAEMON` and `PUREMOUSE_COMPANION_DIR` point into a temporary folder, with a stub daemon
  and the fixture's `status.json`. It refuses if an inherited `PUREMOUSE_CONFIG` or `--out` would
  resolve under `~/.config/puremouse`.
- The full matrix is 293 runs. Expect roughly half an hour on the spare Mac (an estimate, not yet
  timed). Run it there only, never on the Mac whose PureMouse you use (AGENTS.md): its windows open
  on screen.
- `scripts/tests/run.sh ui_matrix` tests the script with a fake helper, so it runs anywhere.
- Not in the matrix: the menu app's hooks (`PureMouseMenu`), the keyboard hooks
  (`PUREMOUSE_DEV_KEY`), and the hooks that pick one of a device's controls or arrivals (`FOUND`,
  `BUTTON`, `ARRIVAL`, `MORE`).

## Other Macs

`scripts/release.sh --dry-run --version 0.0.0-ci.local` builds the universal dmg; for a test Mac,
set `PUREMOUSE_SIGN_IDENTITY=PureMouse` first. On a test Mac over SSH, drive the installed app with
`puremouse register` and `unregister`. Nobody can answer a Gatekeeper dialog or grant permissions
over SSH, so leave those to whoever is at the Mac.

Clear the quarantine flag before the first launch. Launching a quarantined copy parks it at
`_dyld_start` behind an on-screen dialog; on a test Mac, later launches at that path stayed parked
even after clearing the flag and putting a fresh copy there (presumably until the dialog is
answered).

Machine-specific notes belong in the uncommitted `CLAUDE.local.md`.

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
`helper-closed`, `helper-closed-5`, `helper`, `helper-cold-start`, `hidden`, `hidden-doorbells-200`,
`hidden-helper-closed` and `hidden-updates` is also exit 2. `scripts/measure-bare-appkit.sh` measures the bare AppKit comparison.

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
| `hidden`, `hidden-doorbells-200`, `hidden-helper-closed`, `hidden-updates` | the menu app with Show in menu bar off (`PUREMOUSE_DEV_HIDDEN=1`: resident, no status item), fresh; after 200 status doorbells, the last one a low battery; after the helper has opened and quit once; and after an update check (`PUREMOUSE_RIG_UPDATES=check`) |
| `helper-closed-5` | the menu app's footprint after five opens and quits of the helper |

`scripts/measure-menu.budgets` holds `scenario<TAB>limit` lines in the scenario's unit; a scenario
with no line has none. Set them from a run of the build you accept (`--write-budgets`: a
footprint's median plus 2 MB, rounded up; the cold start's plus half, rounded up to 100 ms) and
lower them when a change earns it. Only a Mac with a desktop session can run the rig, so CI does not; repeat it on the
spare Mac after each macOS release (and see `docs/companion.md`, "Footprint", for the figures).

The README's "Lightweight by design" table publishes these figures, the download and installed
sizes (`scripts/size-budget.env`) and the background process's footprint, each labelled with the
version, date and macOS it was measured on. Measure them again for every minor release (X.Y.0),
before tagging it, and update the figures and their labels together; a label still naming an older
version says the figure was not re-taken.

## Reconnect rig

`scripts/measure-reconnect.sh` times how long settings take to come back after a wake, a reconnect
or a host switch-back, and fails above 2 seconds (the bound in
[how-it-works](how-it-works.md#sessions)). It has two legs.

```sh
./scripts/measure-reconnect.sh fake [--cycles N]       # default 10 of each kind; no mouse, daemon or file touched
./scripts/measure-reconnect.sh hardware [--cycles N]   # default 5; on the owner's Mac, with the daemon running
./scripts/measure-reconnect.sh summarise FILE          # a saved run's `rig <kind> <cycle> <ms>` lines
```

- **Fake leg** (automated, any Mac). Runs `ReconnectRigTests` (`PUREMOUSE_RIG_CYCLES=N swift test
  --filter ReconnectRigTests`; off without the variable) against a `FakeDevice` on the daemon's
  live retry schedule: N cycles each of a wake (`configureAfterWake`), a reconnect (a 0x1D4B
  announcement) and a host switch-back (link down, then up). The fake answers no request at all for 0 to 1.3 s
  after the trigger, so the cycles land on the first, second and third attempt, then starts
  answering; the time is from that moment to the session's applied state. It prints a table of
  the median and worst per kind. `PUREMOUSE_RIG_TSV=FILE` also saves the raw lines. These are the
  only wall-clock assertions: the ordinary run (`AppliedStateTests`) counts attempts against a
  scaled schedule instead, so a busy runner cannot fail it, and needs no isolated machine.
- **Hardware leg** (owner assisted). A spare Mac with no mouse can only run the fake leg. With the
  daemon running, the script reads the installed daemon's `status.json` (`PUREMOUSE_COMPANION_DIR`
  picks another) and, for each cycle, waits for you to wake the Mac, switch the mouse off and on, or
  switch it to another computer and back, then reports the time from a device going `applying` to
  `applied`. That includes the mouse waking, so it is a ceiling on the bound: a cycle over 2 s needs
  the log (`configure attempt` lines) to say whether the mouse or PureMouse was slow. It starts nothing
  and writes nothing.

It exits 0 when every cycle is within 2 s, 1 when one is over (the table says which kind) and 2
when the rig itself fails. `scripts/tests/test_measure_reconnect.zsh` tests the summary.

## Signing

`scripts/sign-bundle.sh` signs every build inside out, in the order of `scripts/lib.zsh`'s
`components` (the nested apps, the menu bar app then the Settings helper, first and PureMouse.app
last; a new nested bundle is one more entry), each with its own identifier, without `--deep`, and
always with the hardened runtime. `install.sh` and `uninstall.sh` stop every component's agent and
nested process (each entry is `identifier:path:executable`) before touching the app, signalling
only this user's. The identity is the first of:

1. `PUREMOUSE_SIGN_IDENTITY`;
2. a valid `Developer ID Application` identity in the keychain;
3. the self-signed identity named `PureMouse` (`scripts/make-cert.sh`);
4. ad hoc (`-`).

Local builds sign with `--timestamp=none`; `build-app.sh --timestamp` (and `sign-bundle.sh
--timestamp`) asks for a secure timestamp, which `release.sh` does for a release (it needs the
network, and notarisation needs it). macOS keys permission grants to the identifier plus the
certificate, which also holds on Macs that do not trust the certificate. An ad-hoc build needs them
granted again after every install, and every release must be signed with the same identity: one
signed by any other makes every user grant permissions again. Keep a backup of it.

`scripts/verify-bundle.sh <app>` checks each component: Info.plist present and valid, identifier
and version as expected, `codesign --verify --strict` passing, and every architecture of its
executable signed with that identifier and the runtime flag.
`--release` also requires a release version (`X.Y.Z` or `X.Y.Z-rc.N`) and, when
`PUREMOUSE_TEAM_ID` is set (or `scripts/release.env` sets it), a Developer ID Application
signature from that team.

## Releases

1. For a minor release (X.Y.0), re-take the README's "Lightweight by design" figures first
   ("Footprint rig" above).
2. Tag `vX.Y.Z` (or `vX.Y.Z-rc.N`) on a clean `main` and push the tag. The protected `release`
   environment waits for the owner's approval. The workflow checks that the tagged commit is on
   `main` before importing credentials, then signs, builds and attests the dmg.
3. Review the draft GitHub release and publish it manually. It contains the dmg and `SHA256SUMS`;
   `shasum -a 256 -c SHA256SUMS` checks the download. RC tags produce draft prereleases. Workflow
   artefacts are kept for seven days. A failed run's log shows the build and notary output.

Stable releases require the configured identity and signing secrets. An RC with neither signing
secret is explicitly signed ad hoc and says so in the job summary; partial credentials fail. The
optional notary credentials must be supplied together. Before the first production release, the owner
should approve a throwaway RC and inspect `gh release view <tag>`, verify its downloaded dmg with
`gh attestation verify <dmg> -R mblauberg/PureMouse`, test an off-main tag, and inspect cleanup and
job logs. Delete the throwaway draft and tag afterwards.

For a break-glass local release, run `PUREMOUSE_SIGN_IDENTITY=PureMouse ./scripts/release.sh` on a
Mac holding the existing `PureMouse` identity, then create a draft and attach both files in
`.build/dist`. Naming the identity matters: another certificate makes users grant permissions again.

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
  `scripts/size-budget.env`, each the measured size of the latest release plus 15%, rounded up to
  0.1 MB, plus an allowance (`INSTALLED_EXTRA_BYTES`, `DMG_EXTRA_BYTES`) while a change in flight
  needs one. An allowance is the overshoot of CI's largest figure (`INSTALLED_CI_BYTES`,
  `DMG_CI_BYTES`, taken from the test and compatibility jobs) past the 15% budget, rounded up to
  0.1 MB, so it leaves under 0.1 MB of headroom. The file says what grew, and the next release's
  re-measure (`INSTALLED_MEASURED_BYTES`, `DMG_MEASURED_BYTES`) clears the allowance. Raising a
  budget is a reviewed change that says what grew; `scripts/tests/test_size.zsh` holds the
  arithmetic.
- When the app grows past a budget, re-measure and raise the budget by that rule rather than shrink
  the app at the cost of functionality or polish worth keeping (the owner's rule).

## Repository settings the release relies on

Only the owner changes these, and none needs a Developer ID. Check them with the commands shown.

- Private vulnerability reporting, which `SECURITY.md` links to
  (`gh api repos/mblauberg/PureMouse/private-vulnerability-reporting --jq .enabled`).
- Actions pinned to full SHAs, enforced
  (`gh api repos/mblauberg/PureMouse/actions/permissions --jq .sha_pinning_required`).
- A `main` ruleset requiring the `test` check, and a `v*` tag ruleset that lets only the owner
  create release tags.
- A `release` environment that requires the owner's review and accepts only `v*` tags. Export the
  **existing** PureMouse identity and private key as a password-protected p12; never create a new
  identity for this workflow. Set environment variable `SIGNING_IDENTITY_NAME` to `PureMouse` and
  environment secrets `SIGNING_CERT_P12_BASE64` (base64 of the p12) and `SIGNING_CERT_PASSWORD`
  (its export password). Use `gh variable set SIGNING_IDENTITY_NAME --env release --body PureMouse`
  and `gh secret set SIGNING_CERT_P12_BASE64 --env release < <(base64 -i /path/to/identity.p12)`;
  use `gh secret set SIGNING_CERT_PASSWORD --env release` and enter the password interactively.
  Remove the exported p12 securely after provisioning. If notarisation is configured, also set all
  three environment secrets `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, and
  `NOTARY_API_ISSUER_ID`; supply the base64-encoded p8 to the first in the same way. The workflow
  writes the key with restrictive permissions and removes its temporary files and keychain.
  See [ADR 15](adr/0015-protected-release-workflow.md).
- Discussions, for questions; the issue chooser links to it.

## Icon

The icon is an Icon Composer document, `assets/AppIcon.icon`: a top-down mouse in three
monochrome glass layers (buttons with the centre seam, palm, floating wheel), grey fills with light
and dark specialisations, on the system's light or dark background, so macOS 26+ renders light,
dark, clear and tinted variants. After changing it, run `./scripts/make-icon.sh` (needs Xcode 26+
and `rsvg-convert`) and commit the compiled `Assets.car`, `AppIcon.icns` (the macOS 14 and 15
fallback), the README PNGs (also the About pane's icon) and `MenuBarIcon.pdf`.

The menu bar app and the Settings helper keep their own `Assets.car` (with only the icns, macOS 26+
draws the light icon even in dark mode), but `assemble_bundle` makes both hard links to
PureMouse.app's. codesign, `ditto` and the dmg keep the links, so the 1.8 MB ships once, while
`check-size.sh` still counts it per path. A symlink out of a nested bundle fails codesign.

`assets/MenuBarIcon.svg` is the same mouse as an 18 × 18 pt template: alpha only, the wheel a slot,
gaps of 1 to 1.5 pt on the half-point grid so they stay crisp at 1x and 2x. It is plain clip and
even-odd paths, because `rsvg-convert` rasterises SVG masks in the PDF. The menu bar app loads
`MenuBarIcon.pdf`; keep the SVG and the app icon in step.

## Extending

- **Named button.** Keep `Config.Button` and the menu's `NamedButton` in step (names and CIDs), and
  add the control's display name to `ControlNames` (Kit).
- **Action.** A case in `Action` and a name in `Action.named` (both in PureMouseKit), handled in
  `SystemActions.perform`, or `Session.perform` for device actions.
- **Device feature.** A wrapper in `Sources/HIDPP/Features.swift`, applied in `Session.apply()`,
  with event parsing routed in `Session.handle()`, a parse test in `Tests/HIDPPTests`, its behaviour
  in `FakeDevice` and its readback in a probe fixture.
- **Numeric config field.** Give it a range: numbers are range-checked as they are decoded
  (`decodeIfPresent(_:forKey:in:)` in `Sources/PureMouseKit/Config.swift`). An unchecked value can
  overflow an `Int` or `Duration` conversion mid-session, and during a reload that crash comes after
  the old session has closed, so the mouse is never restored and launchd relaunches into the same
  crash.
- **Config section.** Every section decodes on a `base` (its `init(_:base:)`); a new one takes one,
  keeps its range checks and adds cases to `ConfigGoldenTests`. A config change must keep
  `ConfigGoldenTests` identical, or regenerate it on purpose.
- **Per-app section.** A case in `Config.appSections`, decoding on top of the global value in
  `Config.decodeApps`, a `sets…` flag, and its lookup at the moment it applies.
- **Per-device section.** A case in `Config.deviceSections` and decoding in
  `Config.decodeSections`, the one layering point: the top level decodes its sections there, and
  each device entry decodes its own there on top of the top level's. Add it to
  `ConfigTree.resolved` and to the generator in `DeviceScopeTests.swift` too. Settings' reads
  (`ConfigTree.resolved(_:in:)`, in `ConfigScope.swift`) mirror the decoder's merge (a button per
  control, a gesture per direction, the other sections per key, `dpiPresets` whole), and that test
  checks them against `Config.forDevice` on seeded generated trees, so a change to
  `Config.decodeSections` must keep it green.
- **Thumb-wheel action pair.** `Config.ThumbWheel.presets` (Kit) names the pairs; `ThumbStepper`
  counts rotation into steps (remainder kept, reset at each movement's start), paced per action
  (`ThumbStepper.pacing`: media keys free, shortcuts 50 ms, zoom 40 ms, animated actions 300 ms with
  the turns between discarded). In Settings, `ThumbWheelChoice`
  (`Sources/PureMouseAppSupport/ThumbWheel.swift`) lists Kit's presets in `presetOrder` with a
  label each; `ThumbWheelState` mirrors Kit's `Config.ThumbWheel.init(_:base:)` and a test checks
  it against the decoder. App suggestions are `AppSuggestion.table`.
- **Scroll feel.** `ScrollAcceleration` (the curve) and `ScrollAnimator` (two-part easing) in
  `Sources/puremouse/ScrollModel.swift`, covered by `ScrollModelTests`.

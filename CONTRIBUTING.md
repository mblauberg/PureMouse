# Contributing

Thanks for helping. The most useful contributions, in order:

1. **Support for another mouse.** Open a
   [Device support](https://github.com/mblauberg/PureMouse/issues/new/choose) issue with the output
   of `puremouse probe` ([how to run it](docs/troubleshooting.md#inspecting-a-mouse)). It only
   reads, and [Privacy](docs/privacy.md#what-puremouse-probe-prints) says what it prints, so you can
   check it before pasting.
2. **Bug reports**, with your PureMouse and macOS versions and the lines from
   `~/Library/Logs/PureMouse.log` around the problem.
3. **Feature ideas.** Say what you want to do with the mouse, not only the setting you imagine.

The issue forms ask for what is needed. Questions belong in
[Discussions](https://github.com/mblauberg/PureMouse/discussions), and vulnerabilities go through
[Security](SECURITY.md), not an issue.

## Build and test

```sh
git clone https://github.com/mblauberg/PureMouse.git && cd PureMouse
swift build && swift test
scripts/tests/run.sh
```

You need Xcode or its command line tools. Running a dev build, installing, signing and releases
are in [Development](docs/development.md).

## Design rules

PureMouse exists to be small and to stay out of the way. A change that breaks one of these needs a
very good reason, agreed in an issue first:

- **No dependencies.** System frameworks only. The background process and the shared library use
  no UI toolkit; the menu bar app links AppKit, and only the Settings helper links SwiftUI.
- **Zero idle CPU.** No polling and no timers while nothing is happening: work starts from a device
  event, a file change or a notification. The only exceptions are the two retries the README
  notes under "Lightweight by design".
- **A footprint budget.** Memory and download size are published in the README, and CI fails a
  bundle over its size budget. Say in your pull request what your change costs.
- **Nothing persisted on the mouse.** Every setting is applied again on reconnect and undone on
  quit, so the mouse behaves normally without PureMouse.
- **One process talks to the mouse.** The menu bar app edits the config and talks to the
  background process through files; it never opens the device.
- **Protocol and policy stay apart.** `Sources/HIDPP` knows HID++ only; what to do with it lives in
  `Sources/puremouse`.

[How it works](docs/how-it-works.md) explains the two processes and the source layout, and
[`docs/adr/`](docs/adr/README.md) records why the bigger decisions went the way they did.

## Pull requests

- Keep one change per pull request, and fill in the template.
- Add tests for pure logic (config decoding, scroll maths, state machines). Anything that touches
  the mouse cannot be tested in CI, so say what you checked live: which mouse, which connection
  and which macOS.
- For a visible change in Settings or the menu, include before and after screenshots, in light and
  dark mode.
- Update the docs your change affects: [Configuration](docs/configuration.md) for new config
  fields, and the README for anything a user sees.

`AGENTS.md` is the working contract for coding agents. People do not need to read it; everything
above is the part that applies to you.

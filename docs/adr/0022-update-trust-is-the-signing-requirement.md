# 22. Updates install from the menu, trusted by the app's own code-signing requirement

## Status

Accepted and built (#128). The workshop proof is `scripts/test-update-install.sh`, which signs real
fixtures with throwaway identities. It extends [ADR 21](0021-scheduled-update-check.md), whose
"Installing is still manual" no longer holds: **Update to X.Y.Z…** now installs, after asking.

## Context

The daily check finds a newer release; replacing the app by hand is the one step left. Installing
means running downloaded code as the person, with their Accessibility and Input Monitoring
grants, so the question that matters is what makes a download genuine. PureMouse is signed with a
self-signed identity today (`scripts/make-cert.sh`) and with a Developer ID later
([ADR 19](0019-developer-id-in-one-release.md), #26). Both give a **designated requirement**: the
rule macOS itself uses to decide that a new build is the same app (it is how the Accessibility
grants carry across releases). An update that satisfies the requirement of the running app is, to
macOS, the same app.

## Decision

- **The trust anchor is the running app's code-signing requirement, and nothing from the
  download.** `SecCodeCopySelf` on the running process, `SecCodeCopyDesignatedRequirement`, and
  that text is the requirement every candidate must meet. It is never read from the dmg, the
  release page, `Info.plist` or `SHA256SUMS`. The running process may be the nested menu bar app,
  whose requirement names its own identifier; only that identifier is replaced, with the
  app's frozen one (`io.github.mblauberg.puremouse`), and the certificate part is kept as it is. Only the
  two shapes this project signs with are accepted: `certificate leaf = H"…"` (the self-signed
  identity) and `anchor apple generic … certificate leaf[subject.OU] = …` (Developer ID). An ad-hoc
  signature has only a `cdhash`, which pins nothing across versions, so such a copy is not
  updated by PureMouse (it opens the release page).
- **Checks in order; the first failure stops, and the installed app is untouched.**
  1. The SHA-256 of the dmg equals its line in the release's `SHA256SUMS` (`release.sh` writes
     both). This catches a damaged or truncated download. It is not authenticity: both files come
     from the same place, so the signature is the check that matters.
  2. **The disk image's own signature, before it is mounted.** `release.sh` signs the dmg with the
     release identity. A disk image's identifier is its file name, so the requirement applied to it
     is the certificate part of the running app's alone (`SigningRequirement.certificate(of:)`, the
     parenthesised pin without the identifier clause). An unsigned image, or one signed by another
     certificate, is refused before `hdiutil attach` parses a byte of its filesystem. The checks
     after the mount still apply: the dmg's signature says who made the image, not what the bundle
     inside is.
  3. `hdiutil attach -nobrowse -readonly -noverify` shows exactly one `PureMouse.app` (a real
     directory, not a link) and nothing else that is an app.
  4. `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSStrictValidate |
     kSecCSCheckNestedCode` against the full requirement. It fails for an unsigned app, for another
     certificate, and for any file changed after signing, and each says so.
  5. `CFBundleShortVersionString` is strictly newer than the running version, so a replayed older
     release cannot downgrade, **and equals the version of the release the person approved**, so a
     genuine but different (newer or older) signed build cannot stand in for it. The release page
     must be a tag page; `releases/latest` is refused.
- **Install.** The bundle is copied beside the installed app with `ditto` (same volume, so the swap
  is a rename; `ditto` keeps the hard links that make the nested apps share one `Assets.car`, which
  `FileManager.copyItem` breaks), checked again
  as that copy (the mounted image and the check are not the file that is installed), and swapped in
  with one `FileManager.replaceItemAt(…, options: .usingNewMetadataOnly)`. The image is unmounted and
  the download deleted on every path. PureMouse then quits the helper (reversibly, with no quit
  stamp, so Settings still opens if the relaunch fails) and starts the installed app as
  `puremouse register --relaunch` (`open -n <app> --args register --relaunch`), which restarts the
  background process and the menu bar app on the new files and opens no window. It does not open the
  app the way double-clicking it does: that also opens Settings, which a quiet menu bar utility must
  not do after an update from its menu. Settings comes back only if it was showing (where it was),
  or on About for an update asked for from About, which was showing by definition. The **new** copy
  tries to reopen it (`--settings=<pane>`, once it has registered): `register` replaces the old menu
  bar app, and a helper that is quitting takes a request and exits, so a request from the old
  process would be lost. For the same reason the old process waits, up to 3 s, for the helper to
  exit before it starts the new copy, and goes on regardless after that. Quit or Hide chosen during the
  wait cancels it and starts nothing, with no alert: the update is on disk and the new copy starts at the
  next login. Reopening is best effort:
  if Settings does not come back it opens from the menu. A release older than this one ignores
  `--relaunch` and `--settings`, so it reopens nothing. `open` only says the launch was accepted,
  and the old process is gone by the time registration could fail, so `--relaunch` also has the new
  copy show the Finder launch's alert if it cannot register. There is no acknowledgement back to the
  old process.
- **The commit point is read from the disk.** `replaceItemAt` can throw after the new bundle is in
  place (an immutable flag or a deny-delete ACL on the old bundle gives Cocoa error 513 once the
  rename is done), leaving the old bundle at the staging path. So a throw is not a verdict. The
  installer reads the install path, and either verdict needs the bundle there to pass the full
  signature check against the running requirement, not just carry a version in its `Info.plist`:
  the found version means the update is installed (success; the old copy is removed best-effort,
  clearing flags and ACLs); the running version means it failed (the staged new copy is removed);
  anything else (missing, another version, a bundle that fails its check) keeps the staged copy,
  logs where it is, and reports a failure. The only
  good copy is never deleted. Both causes are reproduced with real files in the workshop proof.
- **Cancel and sweep.** The install runs as a task the menu app keeps. Quit and Hide Menu Bar Icon
  cancel it and wait for it to finish (answering `.terminateLater`), so no image stays mounted and no
  staged copy is left. Cancellation is checked after the download, before the attach, before the
  copy and before the replace; after the replace there is nothing left to stop, and an install that
  commits while the app is leaving does not relaunch. The installer is reserved from the
  confirmation on, so a second request (the menu row again, About, another process writing the
  preference) arriving while the alert is up is refused, `leaving` is checked again after the alert,
  and Quit has exactly one installer to drain. At the start of an install, `PureMouse-update-*` work
  folders (a killed run's leftovers, any image still mounted in them detached first) are removed.
  Staged `.PureMouse-update-*` copies beside the app may be the only good copy (a kept one is what
  an unsettled swap leaves), so they are removed only once the installed app passes the full
  signature check against the running requirement and has a version; otherwise they are all kept,
  nothing is downloaded, and the menu says "Can't update: this copy doesn't verify, so a saved copy
  from an earlier update is kept" with the release page.
- **No prompt and no helper.** If the installed app is on a read-only volume (or running from
  a translocated path), or it, its folder or a folder inside it is not writable by the person
  (an administrator copied it), nothing is downloaded: PureMouse opens the release page and the
  menu says why. There is no password dialog, no privileged helper and no `sudo`.
- **Where.** The menu bar app does it, on the person's say-so (a confirmation alert follows the
  menu row), the one place in the product that downloads. The checksum and dmg come from the
  release the daily check recorded, and the URLs are derived from its tag page, which must be
  under `github.com/mblauberg/PureMouse/releases/tag/`. The image is limited to 64 MB and `SHA256SUMS` to 64 KB; the limit is enforced during the transfer
  (the announced length first, then the bytes as they arrive, deleting the partial file), written to
  a file in 64 KB chunks (not held in memory) and hashed in chunks. `puremouse` and PureMouseKit gain no network
  or install code (`nm` and `strings` on `puremouse`, as in ADR 21).
- **One installer: Settings › About asks the menu app.** Settings is a separate helper process, and
  the installer lives in the menu app. About's **Update and Relaunch** button writes the release
  version it is showing to the menu app's defaults domain (`UpdatesInstallRequestVersion`, with
  `UpdatesInstallRequestPage`); the menu app, which watches that key, validates it against the same
  rules as its own row (a tag page, newer than the running version), clears it, and runs the same
  confirmation and install. Its progress and failure line come back through `UpdatesInstallStatus`
  and show under the button. About offers the button only while the menu app is running, and the
  request makes the menu app active so the alert is seen. The helper never downloads, mounts or
  replaces anything.
- **Off switch.** Installing is always asked for. Turning off **Check for updates automatically**
  removes the offer, so the row never appears; Settings › About › **View Release** still opens the
  page for a manual update.

## The certificate-change caveat

The requirement pins the certificate. When the project moves from the self-signed identity to a
Developer ID ([ADR 19](0019-developer-id-in-one-release.md), #26), a copy signed the old way
refuses the new one: the new release is not "the same app" to the old requirement, and it reports
"The update wasn't signed by the same certificate" with the release page. That is deliberate: it is the
same boundary macOS draws for the permission grants, which also need granting again. The 0.x
release that switches identity is therefore installed by hand once, as ADR 19's release note says.
From then on the requirement is the Developer ID team's, and updates install. The same holds for
anyone who re-signs their own build with another identity: they update their own way.

## Alternatives rejected

- **Sparkle with EdDSA.** A second key to guard and rotate, a framework in a menu
  app whose footprint is budgeted (`scripts/measure-menu.budgets`), and a signature scheme that macOS does not know about: a leaked
  EdDSA key signs updates that the app's own code-signing never agreed to. Here the key is the one
  the system already uses to recognise the app, and a stolen certificate would be a worse problem
  than the update path anyway.
- **Trusting `SHA256SUMS` alone.** It proves the file matches a file from the same server.
- **Reading the requirement from the new bundle** (or from a team ID in `Info.plist`). That lets the
  download choose its own key.
- **Ad-hoc copies updating anyway.** Their requirement is a hash of the code itself, which no
  successor satisfies.
- **Installing through a privileged helper or an `osascript` password prompt.** Code that gains
  root to copy a file, and a habit of typing a password into a dialog the app drew.
- **Replacing the files in place.** A half-copied app after a crash. `replaceItemAt` renames
  whole bundles.
- **Silent updates.** The person chooses each one.

## Consequences

- The menu row **Update to X.Y.Z…** (or Settings › About's **Update and Relaunch**) asks "Update to
  PureMouse X.Y.Z?" and then downloads, checks, replaces and relaunches. A refusal shows one line and
  **View Release**. After a successful swap the row is gone (`.installed`) even if the relaunch
  failed.
- The request is a second kind: a GET of the dmg and `SHA256SUMS` from `github.com`, when the person
  agrees, with no cookies (an ephemeral session). [Privacy](../privacy.md) says so.
- The same requirement keeps the Accessibility and Input Monitoring grants and the settings
  (which live outside the app), so an update asks for nothing again.
- A copy that cannot be replaced by the person falls back to the manual route the README
  describes, with the reason shown.
- The workshop proof (`scripts/test-update-install.sh`) covers every path above with real
  signatures, including a disk image signed by another certificate or unsigned, a different genuine
  version, a swap that throws after committing (immutable flag, deny-delete ACL), a killed run's
  leftovers, hard links, quarantine and the temporary folder. It does not run the relaunch itself on
  an installed copy; that end-to-end step needs the owner's go-ahead on a machine with a real
  install.
- Notarisation (ADR 14) is separate: a notarised release still has to satisfy the requirement.

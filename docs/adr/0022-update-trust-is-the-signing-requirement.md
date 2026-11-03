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
- **Four checks in order; the first failure stops, and the installed app is untouched.**
  1. The SHA-256 of the dmg equals its line in the release's `SHA256SUMS` (`release.sh` writes
     both). This catches a damaged or truncated download. It is not authenticity: both files come
     from the same place, so the signature is the check that matters.
  2. `hdiutil attach -nobrowse -readonly` shows exactly one `PureMouse.app` (a real directory,
     not a link) and nothing else that is an app.
  3. `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSStrictValidate |
     kSecCSCheckNestedCode` against that requirement. It fails for an unsigned app, for another
     certificate, and for any file changed after signing, and each says so.
  4. `CFBundleShortVersionString` is strictly newer than the running version, so a replayed older
     release cannot downgrade.
- **Install.** The bundle is copied beside the installed app (same volume, so the swap is a
  rename), checked again as that copy (the mounted image and the check are not the file that is
  installed), and swapped in with one `FileManager.replaceItemAt`. The image is unmounted and the
  download deleted on every path. PureMouse then opens the installed app the way double-clicking
  it does, which restarts the background process and the menu bar app on the new files.
- **No prompt and no helper.** If the installed app is on a read-only volume (or running from
  a translocated path), or it, its folder or a folder inside it is not writable by the person
  (an administrator copied it), nothing is downloaded: PureMouse opens the release page and the
  menu says why. There is no password dialog, no privileged helper and no `sudo`.
- **Where.** The menu bar app does it, on the person's say-so (a confirmation alert follows the
  menu row), the one place in the product that downloads. The checksum and dmg come from the
  release the daily check recorded, and the URLs are derived from its tag page, which must be
  under `github.com/mblauberg/PureMouse/releases/tag/`. The image is limited to 64 MB, written to
  a file (not held in memory) and hashed in chunks. `puremouse` and PureMouseKit gain no network
  or install code (`nm` and `strings` on `puremouse`, as in ADR 21).
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

- The menu row **Update to X.Y.Z…** asks "Update to PureMouse X.Y.Z?" and then downloads,
  checks, replaces and relaunches. A refusal shows one line and **View Release**.
- The request is a second kind: a GET of the dmg and `SHA256SUMS` from `github.com`, when the person
  agrees, with no cookies (an ephemeral session). [Privacy](../privacy.md) says so.
- The same requirement keeps the Accessibility and Input Monitoring grants and the settings
  (which live outside the app), so an update asks for nothing again.
- A copy that cannot be replaced by the person falls back to the manual route the README
  describes, with the reason shown.
- Notarisation (ADR 14) is separate: a notarised release still has to satisfy the requirement.

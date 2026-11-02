#!/bin/zsh
# Builds the release: .build/dist/PureMouse-X.Y.Z.dmg and SHA256SUMS. It builds the universal app,
# signs it with a secure timestamp, verifies it, notarises and staples it when notary credentials
# exist, puts it in a signed dmg (notarised and stapled likewise), checks both sizes against
# scripts/size-budget.env and the dmg's contents, and writes the checksum.
#
#   release.sh [--dry-run] [--version V]
#
#   (no options)         a release: HEAD must be tagged exactly vX.Y.Z or vX.Y.Z-rc.N on a clean
#                        tree; the version is the tag without the `v`
#   --dry-run            the same steps without notarising and without a timestamp, for CI and
#                        local checks. Takes the version from the tag, or
#   --dry-run --version  0.0.0-ci.<shortsha>: any tree, never a release version
#
# The signing identity is lib.zsh's signing_identity (PUREMOUSE_SIGN_IDENTITY, docs/development.md
# #signing). Notarisation (ADR 14) runs when NOTARY_KEY_PATH (an App Store Connect API key file),
# NOTARY_KEY_ID and NOTARY_ISSUER_ID are all set, and is skipped when none is; some but not all
# fails, and so does a Developer ID signature without them. scripts/release.env holds the Team ID
# the Developer ID signature must carry.
set -euo pipefail
source "${0:A:h}/lib.zsh"
cd $root

usage="usage: release.sh [--dry-run] [--version 0.0.0-ci.<shortsha>]"
dry_run=0 version=
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1; shift ;;
        --version) (( $# >= 2 )) || die "--version needs a value"; version=$2; shift 2 ;;
        *) die $usage ;;
    esac
done

# tag_version: the version HEAD's release tag names, or an explanation of why there is none.
tag_version() {
    local tags=(${(f)"$(git tag --list --points-at HEAD 'v*')"}) valid=() tag
    (( $#tags )) || die "HEAD is not tagged vX.Y.Z or vX.Y.Z-rc.N (a release is built from a tag; for a trial, use --dry-run --version 0.0.0-ci.<shortsha>)"
    for tag in $tags; do
        ! release_version_ok ${tag#v} || valid+=$tag
    done
    (( $#valid )) || die "no tag on HEAD is vX.Y.Z or vX.Y.Z-rc.N: ${(j:, :)tags}"
    (( $#valid == 1 )) || die "HEAD has more than one release tag: ${(j:, :)valid}"
    print -r -- ${valid[1]#v}
}

# notary_credentials: 1 when all three notary variables are set, 0 when none is; dies naming the
# missing ones otherwise.
notary_credentials() {
    local missing=() name
    for name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
        [[ -n ${(P)name:-} ]] || missing+=$name
    done
    case $#missing in
        0) [[ -f $NOTARY_KEY_PATH ]] || die "NOTARY_KEY_PATH is not a file: $NOTARY_KEY_PATH"; print 1 ;;
        3) print 0 ;;
        *) die "incomplete notary credentials: missing ${(j:, :)missing}" ;;
    esac
}

notary_auth=(--key "${NOTARY_KEY_PATH:-}" --key-id "${NOTARY_KEY_ID:-}" --issuer "${NOTARY_ISSUER_ID:-}")

# notarize <file>: submits it and waits; on anything but Accepted, prints Apple's log and dies.
# Stapling is the caller's: a zip cannot be stapled.
notarize() {
    local file=$1 output result id
    echo "notarising ${file:t}"
    output=$(xcrun notarytool submit $file $notary_auth --wait --output-format json 2>&1) || true
    result=$(print -r -- $output | plutil -extract status raw -o - - 2>/dev/null) || result=
    if [[ $result != Accepted ]]; then
        id=$(print -r -- $output | plutil -extract id raw -o - - 2>/dev/null) || id=
        [[ -z $id ]] || xcrun notarytool log $id $notary_auth >&2 || true
        die "notarisation of ${file:t} failed (${result:-no result}): $output"
    fi
}

# verify_dmg <dmg> [verify-bundle.sh options]: mounts it read-only, out of sight of the Finder, and
# checks that it holds PureMouse.app, which verify-bundle.sh accepts, and the Applications link.
verify_dmg() {
    local dmg=$1 mount=$(mktemp -d) problem=
    shift
    hdiutil attach -nobrowse -readonly -noverify -mountpoint $mount $dmg >/dev/null ||
        die "could not mount ${dmg:t}"
    [[ -L $mount/Applications && $(readlink $mount/Applications) == /Applications ]] ||
        problem="no Applications link to /Applications"
    [[ -n $problem ]] || scripts/verify-bundle.sh $mount/PureMouse.app $@ || problem="PureMouse.app does not verify"
    hdiutil detach -quiet $mount || hdiutil detach -quiet -force $mount
    rmdir $mount
    [[ -z $problem ]] || die "${dmg:t}: $problem"
}

if [[ -n $version ]]; then
    (( dry_run )) || die "--version is only for a --dry-run (a release takes its version from its tag)"
    [[ $version =~ '^0\.0\.0-ci\.[0-9A-Za-z]+$' ]] || die "a dry run's --version must be 0.0.0-ci.<shortsha>, not '$version'"
else
    version=$(tag_version)
fi
notarise=0
if (( ! dry_run )); then
    [[ -z $(git status --porcelain) ]] || die "the working tree is not clean; a release is built from a clean tree"
    notarise=$(notary_credentials)
fi

app=.build/app/PureMouse.app
dist=.build/dist
dmg=$dist/PureMouse-$version.dmg
identity=$(signing_identity)
verify=($app)

scripts/build-app.sh --universal --version $version
[[ $(plist_value $app/Contents/Info.plist CFBundleShortVersionString) == $version ]] ||
    die "the built app is not version $version"
if (( ! dry_run )); then
    # build-app.sh signs without a timestamp; Apple's notary service and a release need one.
    scripts/sign-bundle.sh $app --identity "$identity" --timestamp
    verify+=(--release)
fi
scripts/verify-bundle.sh $verify
scripts/check-size.sh $app

if (( notarise )); then
    work=$(mktemp -d)
    trap 'rm -rf $work' EXIT
    ditto -c -k --keepParent $app $work/PureMouse.zip
    notarize $work/PureMouse.zip
    xcrun stapler staple $app
elif (( dry_run )); then
    echo "dry run: not notarising"
else
    if codesign -dvv $app 2>&1 | grep '^Authority=Developer ID Application: ' >/dev/null; then
        die "PureMouse.app is signed with a Developer ID, so it must be notarised: set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID"
    fi
    echo "no notary credentials: skipping notarisation"
fi

mkdir -p $dist
rm -f $dmg $dist/SHA256SUMS
dmg_options=(--identity "$identity")
(( dry_run )) || dmg_options+=(--timestamp)
scripts/make-dmg.sh $app $dmg $dmg_options
if (( notarise )); then
    notarize $dmg
    xcrun stapler staple $dmg
fi
verify_dmg $dmg $verify[2,-1]
scripts/check-size.sh $dmg
(cd $dist && shasum -a 256 ${dmg:t} > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
(( ! dry_run )) || echo "dry run: $dmg is for checking, not for publishing"

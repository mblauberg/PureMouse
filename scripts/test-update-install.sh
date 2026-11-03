#!/bin/zsh
# Proves the update install with real code signatures: builds two PureMouse versions signed by a
# throwaway identity in a temporary keychain, makes releases of them (a dmg and SHA256SUMS, as
# release.sh does), then runs the shipping pipeline (Tests/PureMouseAppSupportTests/InstallProbe)
# against a copy of the older app in a temporary Applications folder: the good release replaces it,
# and each bad one (hash mismatch, signed by a second identity, unsigned, modified after signing, not
# newer) leaves it untouched. A folder that cannot be written and a read-only volume must open the
# release page without downloading anything. After every case, no download and no mounted image may
# remain.
#
#   test-update-install.sh --dir <work dir> [--bin <folder>] [--keep]
#
#   --dir     the work dir is created and removed (--keep leaves it)
#   --bin     a folder holding built puremouse, PureMouseMenu and PureMouseSettings binaries, for a Mac
#             without the SwiftUI macro plugin (Command Line Tools only); otherwise they are built here
#
# Needs a Mac that can sign and build (the workshop). It never touches /Applications, the real
# login agents or the login keychain's contents, only adds the temporary keychain to the search
# list while it runs, and removes it again. Not part of CI: docs/development.md.
set -euo pipefail
source "${0:A:h}/lib.zsh"
cd $root

usage="usage: test-update-install.sh --dir <work dir> [--bin <folder>] [--keep]"
work= keep=0 bin=
while (( $# )); do
    case $1 in
        --dir) (( $# >= 2 )) || die $usage; work=$2; shift 2 ;;
        --bin) (( $# >= 2 )) || die $usage; bin=${2:A}; shift 2 ;;
        --keep) keep=1; shift ;;
        *) die $usage ;;
    esac
done
[[ -n $work ]] || die $usage
[[ ! -e $work ]] || die "$work exists; give a new folder"
[[ $work != /Applications* ]] || die "never inside /Applications"
mkdir -p $work
work=${work:A}

old_version=0.5.0 new_version=0.6.0
keychain=$work/update-test.keychain-db
password=throwaway-$RANDOM-$RANDOM
identity_a="PM Update Test A" identity_b="PM Update Test B"
apps=$work/Applications      # the temporary Applications folder
scratch=$work/tmp            # TMPDIR of every probe: the download location
rom=$work/readonly-volume
rom_mount=
failures=0
original_keychains=(${(f)"$(security list-keychains -d user | sed 's/^ *"//; s/"$//')"})

cleanup() {
    local result=$?
    chmod -R u+w $apps 2>/dev/null || true
    [[ -z $rom_mount ]] || hdiutil detach -quiet -force $rom_mount 2>/dev/null || true
    security list-keychains -d user -s $original_keychains 2>/dev/null || true
    security delete-keychain $keychain 2>/dev/null || true
    if (( keep )); then
        print "kept $work"
    else
        chmod -R u+w $work 2>/dev/null || true
        rm -rf $work
    fi
    exit $result
}
trap cleanup EXIT
trap 'exit 130' INT TERM

check() {   # check <description> <command...>
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        print -- "  ok    $description"
    else
        print -- "  FAIL  $description"
        failures=$((failures + 1))
    fi
}

mkdir -p $apps $scratch

print -- "== two throwaway identities in a temporary keychain"
security create-keychain -p $password $keychain
security set-keychain-settings $keychain
security unlock-keychain -p $password $keychain
security list-keychains -d user -s $keychain $original_keychains
for name in $identity_a $identity_b; do
    PUREMOUSE_SIGN_IDENTITY=$name PUREMOUSE_KEYCHAIN=$keychain scripts/make-cert.sh
done
security set-key-partition-list -S apple-tool:,apple: -s -k $password $keychain >/dev/null

print -- "== build $new_version signed by A; derive $old_version and the bad variants"
if [[ -z $bin ]]; then
    for product in ${components##*:}; do
        swift build -c release --product $product
    done
    bin=$(swift build -c release --show-bin-path)
fi
fixtures=$work/fixtures
mkdir -p $fixtures
new_app=$fixtures/new/PureMouse.app
old_app=$fixtures/old/PureMouse.app
mkdir -p $fixtures/new $fixtures/old
assemble_bundle $bin $new_app $new_version 1
scripts/sign-bundle.sh $new_app --identity $identity_a

# retag <app> <version>: the same bundle at another version, signed again by A.
retag() {
    local app=$1 version=$2 component
    for component in $components; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$(component_path $app $component)/Contents/Info.plist"
    done
    scripts/sign-bundle.sh $app --identity $identity_a
}
ditto $new_app $old_app
retag $old_app $old_version

# release <name> <app> <version> [wrong-hash]: fixtures/<name>/PureMouse-<version>.dmg and SHA256SUMS.
release() {
    local name=$1 app=$2 version=$3 dir=$fixtures/$1
    mkdir -p $dir
    scripts/make-dmg.sh $app $dir/PureMouse-$version.dmg >/dev/null
    (cd $dir && shasum -a 256 PureMouse-$version.dmg > SHA256SUMS)
    if [[ ${4:-} == wrong-hash ]]; then
        print -- "$(printf '%064d' 0)  PureMouse-$version.dmg" > $dir/SHA256SUMS
    fi
}

release good $new_app $new_version
release bad-hash $new_app $new_version wrong-hash

mkdir -p $fixtures/other-cert
ditto $new_app $fixtures/other-cert/PureMouse.app
scripts/sign-bundle.sh $fixtures/other-cert/PureMouse.app --identity $identity_b
release other-cert $fixtures/other-cert/PureMouse.app $new_version

mkdir -p $fixtures/unsigned
ditto $new_app $fixtures/unsigned/PureMouse.app
for component in $components; do
    codesign --remove-signature "$(component_path $fixtures/unsigned/PureMouse.app $component)"
done
release unsigned $fixtures/unsigned/PureMouse.app $new_version

mkdir -p $fixtures/modified
ditto $new_app $fixtures/modified/PureMouse.app
print -n " " >> $fixtures/modified/PureMouse.app/Contents/Resources/config.example.json
release modified $fixtures/modified/PureMouse.app $new_version

# A release page that carries the version already installed: not newer.
release not-newer $old_app $new_version

print -- "== the probe, signed as the menu bar app by A"
swift build --product InstallProbe >/dev/null
probe=$work/InstallProbe
cp "$(swift build --show-bin-path)/InstallProbe" $probe
codesign --force --sign $identity_a --identifier $menu_label $probe
print -- "requirement derived from the running process:"
print -- "  $($probe requirement)"
check "it pins the certificate of A under the app's identifier" \
    [ "$($probe requirement)" = "identifier \"$label\" and (certificate leaf = H\"$(codesign -d -r- $old_app 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p')\")" ]

mounted() { hdiutil info | grep -c 'PureMouse-update' || true; }
fingerprint() {   # fingerprint <app>: the inode and every file's hash
    print -- "$(stat -f %i $1) $(find $1 -type f -exec shasum -a 256 {} + | sort | shasum -a 256)"
}
leftovers() { print -l $scratch/*(N) $apps/.PureMouse-update-*(N); }

# fresh_install: a clean temporary Applications folder holding the older app.
fresh_install() {
    chmod -R u+w $apps 2>/dev/null || true
    rm -rf $apps
    mkdir -p $apps
    ditto $old_app $apps/PureMouse.app
}

# rejected <case> <fixture> <expected failure> <running version>
rejected() {
    local name=$1 fixture=$2 expected=$3 running=${4:-$old_version}
    print -- "== $name"
    fresh_install
    local before=$(fingerprint $apps/PureMouse.app) output
    output=$(TMPDIR=$scratch/ $probe $fixtures/$fixture $apps/PureMouse.app $running $new_version 2>$work/stderr) || true
    print -- "  menu would say: ${output#*| }"
    check "failed with $expected" [ "${output%% |*}" = "failed $expected" ]
    check "the installed app is byte-for-byte untouched" [ "$(fingerprint $apps/PureMouse.app)" = "$before" ]
    check "the installed app is still $old_version" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $old_version ]
    check "no file left in the download location or beside the app" [ -z "$(leftovers)" ]
    check "no image still mounted" [ "$(mounted)" = 0 ]
}

print -- "== a good release replaces the older app"
fresh_install
before_requirement=$(codesign -d -r- $apps/PureMouse.app 2>&1 | grep '^designated')
before_inode=$(stat -f %i $apps/PureMouse.app)
output=$(TMPDIR=$scratch/ $probe $fixtures/good $apps/PureMouse.app $old_version $new_version 2>$work/stderr) || true
print -- "  $output"
check "installed $new_version" [ "$output" = "installed $new_version" ]
check "the installed app is now $new_version" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $new_version ]
check "it is a different bundle on disk" [ "$(stat -f %i $apps/PureMouse.app)" != "$before_inode" ]
check "its signature is intact (strict, deep)" codesign --verify --strict --deep $apps/PureMouse.app
check "its designated requirement is unchanged, so the Accessibility and Input Monitoring grants carry over" \
    [ "$(codesign -d -r- $apps/PureMouse.app 2>&1 | grep '^designated')" = "$before_requirement" ]
print -- "  $before_requirement"
check "the new daemon binary runs and prints its usage" [ "$($apps/PureMouse.app/Contents/MacOS/puremouse help 2>&1 | head -1 | cut -c1-6)" = usage: ]
check "no file left in the download location or beside the app" [ -z "$(leftovers)" ]
check "nothing but PureMouse.app in the folder" [ "$(ls -A $apps)" = PureMouse.app ]
check "no image still mounted" [ "$(mounted)" = 0 ]
check "the only downloads were the checksums and the image" [ "$(sort $work/stderr | grep '^download' | tr '\n' ' ')" = "download PureMouse-$new_version.dmg download SHA256SUMS " ]

rejected "SHA256SUMS does not match the image" bad-hash checksumMismatch
rejected "signed by another certificate" other-cert wrongCertificate
rejected "unsigned" unsigned unsigned
rejected "a file modified after signing" modified modified
rejected "not newer (same version)" not-newer notNewer
rejected "not newer (running a later version)" good notNewer 0.7.0

print -- "== the installed app is not writable: the release page opens, nothing downloads, no password"
fresh_install
chmod a-w $apps
output=$(TMPDIR=$scratch/ $probe $fixtures/good $apps/PureMouse.app $old_version $new_version 2>$work/stderr) || true
chmod u+w $apps
print -- "  $output"
check "failed as cannot-install-here and opens the release page" [ "${output%% |*}" = "failed cannotInstallHere(PureMouseAppSupport.UpdateInstallFailure.Place.notWritable)" ]
check "opens-release-page=true" [ "${output##*opens-release-page=}" = true ]
check "nothing was downloaded" [ -z "$(grep '^download' $work/stderr)" ]
check "the installed app is untouched" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $old_version ]
check "no file left in the download location" [ -z "$(leftovers)" ]

print -- "== the installed app is on a read-only volume"
hdiutil create -size 20m -fs HFS+ -volname PureMouseRO -ov $rom-rw.dmg >/dev/null
rw_mount=$work/rw-mount
mkdir -p $rw_mount
hdiutil attach -nobrowse -noverify -mountpoint $rw_mount $rom-rw.dmg >/dev/null
ditto $old_app $rw_mount/PureMouse.app
hdiutil detach -quiet $rw_mount
hdiutil convert $rom-rw.dmg -format UDRO -o $rom.dmg >/dev/null
rom_mount=$work/ro-mount
mkdir -p $rom_mount
hdiutil attach -nobrowse -readonly -noverify -mountpoint $rom_mount $rom.dmg >/dev/null
output=$(TMPDIR=$scratch/ $probe $fixtures/good $rom_mount/PureMouse.app $old_version $new_version 2>$work/stderr) || true
print -- "  $output"
check "failed as cannot-install-here and opens the release page" [ "${output%% |*}" = "failed cannotInstallHere(PureMouseAppSupport.UpdateInstallFailure.Place.readOnlyVolume)" ]
check "nothing was downloaded" [ -z "$(grep '^download' $work/stderr)" ]
check "no file left in the download location" [ -z "$(leftovers)" ]
hdiutil detach -quiet $rom_mount
rom_mount=

print
if (( failures )); then
    print -- "$failures check(s) failed"
    exit 1
fi
print -- "all checks passed"

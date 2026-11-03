#!/bin/zsh
# Proves the update install with real code signatures: builds two PureMouse versions signed by a
# throwaway identity in a temporary keychain, makes releases of them (a dmg and SHA256SUMS, as
# release.sh does), then runs the shipping pipeline (Tests/PureMouseAppSupportTests/InstallProbe)
# against a copy of the older app in a temporary Applications folder: the good release replaces it,
# and each bad one (hash mismatch, signed by a second identity, unsigned, modified after signing, not
# newer, not the announced version, a disk image that is not signed by the same identity) leaves it
# untouched. A swap that throws after committing (an immutable file, a deny-delete ACL) ends with the
# new app installed and nothing left over, and a killed install's leftovers are swept. A folder that cannot be written and a read-only volume must open the
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
#
# If it is killed hard (kill -9) the temporary keychain stays in the search list; put the login
# keychain back with:  security list-keychains -d user -s ~/Library/Keychains/login.keychain-db
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
# Decide where this will write before anything is created: the real path of the parent (symlinks and
# `..` resolved), with a name of its own that is not itself a link, outside the places this must never
# touch. A check on the text alone passes /Users/../Applications/x and a symlinked parent.
[[ ${work:t} != (.|..|) ]] || die "give a new folder name, not '$work'"
[[ -d ${work:h} ]] || die "the parent of $work does not exist"
parent=${${work:h}:A}
work=$parent/${work:t}
[[ ! -e $work && ! -L $work ]] || die "$work exists; give a new folder"
case ${(L)work} in
    /|/applications|/applications/*|/system|/system/*|/library|/library/*|/usr/*|/bin/*|/sbin/*|/private/etc/*|/private/var/db/*|/opt/*)
        die "refusing $work: it is in /Applications or a system folder" ;;
esac
mkdir $work

old_version=0.5.0 new_version=0.6.0
keychain=$work/update-test.keychain-db
password=throwaway-$RANDOM-$RANDOM
identity_a="PM Update Test A" identity_b="PM Update Test B"
apps=$work/Applications      # the temporary Applications folder
scratch=$work/tmp            # the probe's download location (its base directory)
user_temp=$(getconf DARWIN_USER_TEMP_DIR)   # where Foundation puts it by default, whatever TMPDIR says
rom=$work/readonly-volume
rom_mount=
rw_mount=
stale_mount=
failures=0
original_keychains=(${(f)"$(security list-keychains -d user | sed 's/^ *"//; s/"$//')"})

cleanup() {
    local result=$?
    chflags -R nouchg $apps 2>/dev/null || true
    chmod -R -N $apps 2>/dev/null || true
    chmod -R u+w $apps 2>/dev/null || true
    local mount
    for mount in $rom_mount $rw_mount $stale_mount; do
        [[ -z $mount ]] || hdiutil detach -quiet -force $mount 2>/dev/null || true
    done
    security list-keychains -d user -s $original_keychains 2>/dev/null || true
    security delete-keychain $keychain 2>/dev/null || true
    if (( keep )); then
        print "kept $work"
    else
        chflags -R nouchg $work 2>/dev/null || true
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
# The dmg is signed by $dmg_identity (A unless a case says otherwise; "none" leaves it unsigned), as
# release.sh signs it with the release identity.
dmg_identity=$identity_a
release() {
    local name=$1 app=$2 version=$3 dir=$fixtures/$1
    mkdir -p $dir
    if [[ $dmg_identity == none ]]; then
        scripts/make-dmg.sh $app $dir/PureMouse-$version.dmg >/dev/null
    else
        scripts/make-dmg.sh $app $dir/PureMouse-$version.dmg --identity $dmg_identity >/dev/null
    fi
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

# The app inside is genuine (signed by A), the dmg is not: refused before it is mounted.
dmg_identity=$identity_b release image-other-cert $new_app $new_version
dmg_identity=none release image-unsigned $new_app $new_version

# A newer app than the release page announced, in an image named for the announced version.
mkdir -p $fixtures/later
ditto $new_app $fixtures/later/PureMouse.app
retag $fixtures/later/PureMouse.app 0.7.0
release later $fixtures/later/PureMouse.app $new_version

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
catalogues() {   # catalogues <app>: how many distinct Assets.car files the app and its nested apps hold
    local component
    for component in $components; do stat -f %i "$(component_path $1 $component)/Contents/Resources/Assets.car"; done | sort -u | wc -l | tr -d ' '
}
quarantined() { xattr -lr $1 2>/dev/null | grep -c 'com.apple.quarantine' || true; }
user_temp_leftovers() { print -l $user_temp/PureMouse-update-*(N) | wc -l | tr -d ' '; }
fingerprint() {   # fingerprint <app>: the inode and every file's hash
    print -- "$(stat -f %i $1) $(find $1 -type f -exec shasum -a 256 {} + | sort | shasum -a 256)"
}
# Anything the probe left: in its own download location (it is told to use it), beside the app, or in
# the real per-user temporary folder, where an install that ignored its base would have put it.
temp_before=$(user_temp_leftovers)
leftovers() {
    print -l $scratch/*(N) $apps/.PureMouse-update-*(N)
    [[ $(user_temp_leftovers) == $temp_before ]] || print "a PureMouse-update folder in $user_temp"
}
# run_probe <release folder> <app> <running version> [release version]
run_probe() { INSTALL_PROBE_TMP=$scratch $probe $1 $2 $3 ${4:-$new_version} 2>$work/stderr; }
check "the fixture's three Assets.car are one file" [ "$(catalogues $new_app)" = 1 ]

installed_is_new() {
    [[ $(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString) == $new_version ]] &&
        codesign --verify --strict --deep $apps/PureMouse.app
}

# fresh_install: a clean temporary Applications folder holding the older app.
fresh_install() {
    chflags -R nouchg $apps 2>/dev/null || true
    chmod -R -N $apps 2>/dev/null || true
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
    output=$(run_probe $fixtures/$fixture $apps/PureMouse.app $running) || true
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
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
print -- "  $output"
check "the probe worked in the folder it was given" grep -q "^work-base $scratch\$" $work/stderr
check "installed $new_version" [ "$output" = "installed $new_version" ]
check "the installed app is now $new_version" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $new_version ]
check "it is a different bundle on disk" [ "$(stat -f %i $apps/PureMouse.app)" != "$before_inode" ]
check "its signature is intact (strict, deep)" codesign --verify --strict --deep $apps/PureMouse.app
check "its designated requirement is unchanged, so the Accessibility and Input Monitoring grants carry over" \
    [ "$(codesign -d -r- $apps/PureMouse.app 2>&1 | grep '^designated')" = "$before_requirement" ]
print -- "  $before_requirement"
check "the new daemon binary runs and prints its usage" [ "$($apps/PureMouse.app/Contents/MacOS/puremouse help 2>&1 | head -1 | cut -c1-6)" = usage: ]
check "no quarantine flag on the installed app or anything in it" [ "$(quarantined $apps/PureMouse.app)" = 0 ]
check "the app and its nested apps still share one Assets.car (the hard links survived the copy)" [ "$(catalogues $apps/PureMouse.app)" = 1 ]
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
rejected "a newer app than the release page announced" later notTheRelease
rejected "the disk image is signed by another certificate (the app inside is genuine)" image-other-cert wrongCertificate
rejected "the disk image is unsigned (the app inside is genuine)" image-unsigned unsigned
# In both image cases the app inside is genuine, so only the image's own signature can have refused
# them: the check happens before anything is mounted or parsed.

# An earlier install that was killed: a staged copy beside the app, and a work folder with its image
# still mounted. The next install sweeps both.
print -- "== what a killed install left is swept by the next"
fresh_install
mkdir -p $apps/.PureMouse-update-deadbeef/Contents $scratch/PureMouse-update-OLD/image
echo x > $apps/.PureMouse-update-deadbeef/Contents/x
hdiutil create -size 5m -fs HFS+ -volname PMStale -ov $work/stale.dmg >/dev/null
hdiutil attach -nobrowse -noverify -mountpoint $scratch/PureMouse-update-OLD/image $work/stale.dmg >/dev/null
stale_mount=$scratch/PureMouse-update-OLD/image
check "the stale image is mounted to begin with" [ "$(mounted)" != 0 ]
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
stale_mount=
check "installed $new_version" [ "$output" = "installed $new_version" ]
check "the stale staged copy and work folder are gone" [ -z "$(leftovers)" ]
check "the stale image was detached" [ "$(mounted)" = 0 ]

# A copy an earlier install preserved is the only good one when the installed app is damaged, so the
# next install keeps it and refuses, without downloading, until the installed app verifies.
print -- "== a preserved copy is kept while the installed app is damaged"
fresh_install
ditto $new_app $apps/.PureMouse-update-cafe1234
config=$apps/PureMouse.app/Contents/Resources/config.example.json
cp $config $work/config.original
print -- "damaged" >> $config
kept_before=$(fingerprint $apps/.PureMouse-update-cafe1234)
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
print -- "  menu would say: ${output#*| }"
check "refused as a damaged copy, and opens the release page" \
    [ "${output%% |*}" = "failed cannotInstallHere(PureMouseAppSupport.UpdateInstallFailure.Place.damaged)" ]
check "nothing was downloaded" [ -z "$(grep '^download' $work/stderr)" ]
check "the preserved copy is still there, byte for byte" [ "$(fingerprint $apps/.PureMouse-update-cafe1234)" = "$kept_before" ]
check "the preserved copy verifies (strict, deep)" codesign --verify --strict --deep $apps/.PureMouse-update-cafe1234
cp $work/config.original $config
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
check "once the installed app verifies again, the install goes ahead" [ "$output" = "installed $new_version" ]
check "and the preserved copy is swept" [ -z "$(leftovers)" ]

# The swap can also throw before anything is replaced (an ACL on the folder that denies deleting its
# entries passes the writability check and then refuses the rename, Cocoa 513). Here the app at the install path has the running version in its Info.plist but fails its signature,
# so the disk does not say it is the old app: the staged new copy, which may be the only good one, stays.
print -- "== the swap throws with a damaged old app in place: the staged copy is kept"
fresh_install
config=$apps/PureMouse.app/Contents/Resources/config.example.json
print -- "damaged" >> $config
chmod +a "everyone deny delete_child" $apps
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
chmod -a "everyone deny delete_child" $apps
print -- "  $output"
kept=$(print -l $apps/.PureMouse-update-*(N))
check "failed as a failed install" [ "${output%% |*}" = "failed installFailed" ]
check "exactly one staged copy was kept" [ "$(print -l $apps/.PureMouse-update-*(N) | grep -c .)" = 1 ]
check "the old app was not replaced" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $old_version ]
check "the kept copy is $new_version and verifies (strict, deep)" \
    [ "$(plist_value $kept/Contents/Info.plist CFBundleShortVersionString)" = $new_version ] && codesign --verify --strict --deep $kept
check "no image still mounted" [ "$(mounted)" = 0 ]

# The swap can throw after the new app is in place (an immutable resource, a deny-delete ACL). The disk
# decides: the new app is installed, it verifies, and the old copy that could not be deleted is cleaned.
for fault in immutable-flag deny-delete-acl; do
    print -- "== the swap throws after committing ($fault)"
    fresh_install
    target=$apps/PureMouse.app/Contents/Resources/config.example.json
    if [[ $fault == immutable-flag ]]; then chflags uchg $target; else chmod +a "everyone deny delete" $target; fi
    output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
    print -- "  $output"
    chflags nouchg $target 2>/dev/null || true
    check "installed $new_version" [ "$output" = "installed $new_version" ]
    check "the installed app is $new_version and verifies (strict, deep)" installed_is_new
    check "the old copy it could not delete is cleaned up as well" [ -z "$(leftovers)" ]
    check "no image still mounted" [ "$(mounted)" = 0 ]
done

print -- "== the installed app is not writable: the release page opens, nothing downloads, no password"
fresh_install
chmod a-w $apps
output=$(run_probe $fixtures/good $apps/PureMouse.app $old_version) || true
chmod u+w $apps
print -- "  $output"
check "failed as cannot-install-here and opens the release page" [ "${output%% |*}" = "failed cannotInstallHere(PureMouseAppSupport.UpdateInstallFailure.Place.notWritable)" ]
check "opens-release-page=true" [ "${output##*opens-release-page=}" = true ]
check "nothing was downloaded" [ -z "$(grep '^download' $work/stderr)" ]
check "the installed app is untouched" [ "$(plist_value $apps/PureMouse.app/Contents/Info.plist CFBundleShortVersionString)" = $old_version ]
check "no file left in the download location" [ -z "$(leftovers)" ]

print -- "== the installed app is on a read-only volume"
hdiutil create -size 20m -fs HFS+ -volname PureMouseRO -ov $rom-rw.dmg >/dev/null
mkdir -p $work/rw-mount
rw_mount=$work/rw-mount      # tracked, so cleanup detaches it if ditto fails or this is interrupted
hdiutil attach -nobrowse -noverify -mountpoint $rw_mount $rom-rw.dmg >/dev/null
ditto $old_app $rw_mount/PureMouse.app
hdiutil detach -quiet $rw_mount
rw_mount=
hdiutil convert $rom-rw.dmg -format UDRO -o $rom.dmg >/dev/null
rom_mount=$work/ro-mount
mkdir -p $rom_mount
hdiutil attach -nobrowse -readonly -noverify -mountpoint $rom_mount $rom.dmg >/dev/null
output=$(run_probe $fixtures/good $rom_mount/PureMouse.app $old_version) || true
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

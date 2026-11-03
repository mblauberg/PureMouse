#!/bin/zsh
# Checks a signed PureMouse.app before anyone installs or ships it, and names every component that
# fails. For each bundle in lib.zsh's `components`: its Info.plist is present and valid, its
# identifier is the frozen label (in the plist and the signature), its signature verifies strictly,
# every architecture of its executable is signed with that identifier and the hardened runtime, and
# its version matches the app's. Every slice must record the configured deployment minimum and
# macOS SDK 26 or later, so supported systems get the current native appearance.
#
#   verify-bundle.sh <app> [--release]
#
#   --release  also: the version is a release version (X.Y.Z or X.Y.Z-rc.N), and when
#              PUREMOUSE_TEAM_ID is set every component is signed by a Developer ID Application
#              identity of that team. A variable already set wins; otherwise scripts/release.env
#              sets it. Empty means no team, and only the base checks run.
set -euo pipefail
source "${0:A:h}/lib.zsh"

app= release=0
for argument; do
    case $argument in
        --release) release=1 ;;
        -*) die "usage: verify-bundle.sh <app> [--release]" ;;
        *) [[ -z $app ]] || die "one app at a time"; app=$argument ;;
    esac
done
[[ -n $app && -d $app ]] || die "usage: verify-bundle.sh <app> [--release]"
(( ! release )) || load_env_file $root/scripts/release.env
team=${PUREMOUSE_TEAM_ID:-}
[[ -z $team || $team =~ '^[A-Z0-9]{10}$' ]] || die "PUREMOUSE_TEAM_ID '$team' is not a 10-character team ID"

failed=0
fail() {
    print -u2 -- "FAIL $*"
    failed=1
}

app_version=$(plist_value $app/Contents/Info.plist CFBundleShortVersionString || true)
app_build=$(plist_value $app/Contents/Info.plist CFBundleVersion || true)
if (( release )) && ! release_version_ok "$app_version"; then
    fail "$app: version '$app_version' is not a release version (X.Y.Z or X.Y.Z-rc.N)"
fi

for component in $components; do
    expected=$(component_id $component)
    bundle=$(component_path $app $component)
    name=${bundle:t}
    plist=$bundle/Contents/Info.plist
    if [[ ! -f $plist ]]; then
        fail "$name: no Contents/Info.plist"
        continue
    fi
    plutil -lint -s $plist || fail "$name: Info.plist does not parse"
    identifier=$(plist_value $plist CFBundleIdentifier || true)
    [[ $identifier == "$expected" ]] || fail "$name: CFBundleIdentifier is '$identifier', not $expected"
    for key in CFBundleShortVersionString:$app_version CFBundleVersion:$app_build; do
        value=$(plist_value $plist ${key%%:*} || true)
        [[ $value == "${key#*:}" ]] || fail "$name: ${key%%:*} is '$value', not '${key#*:}' as in the app"
    done

    if ! codesign --verify --strict $bundle 2>/dev/null; then
        fail "$name: signature does not verify ($(codesign --verify --strict $bundle 2>&1 | tail -1))"
    fi
    # `codesign -d` shows one architecture (this Mac's) unless told which, so read each slice: a
    # universal build could otherwise ship an Intel slice without the hardened runtime.
    executable=$bundle/Contents/MacOS/$(plist_value $plist CFBundleExecutable || true)
    if ! archs=($(lipo -archs $executable 2>/dev/null)); then
        fail "$name: no executable at ${executable#$app/}"
        continue
    fi
    signed_ok=1
    for arch in $archs; do
        if build_info=$(xcrun vtool -arch $arch -show-build $executable 2>&1); then
            platform=$(print -r -- $build_info | awk '$1 == "platform" {print $2}')
            minos=$(print -r -- $build_info | awk '$1 == "minos" {print $2}')
            sdk=$(print -r -- $build_info | awk '$1 == "sdk" {print $2}')
            [[ $platform == MACOS ]] || fail "$executable ($arch): platform is '$platform', not MACOS"
            [[ $minos == $minimum ]] || fail "$executable ($arch): minos is '$minos', not $minimum"
            if [[ ! $sdk =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || (( ${sdk%%.*} < minimum_sdk )); then
                fail "$executable ($arch): SDK is '$sdk', needs macOS $minimum_sdk or later"
            fi
        else
            fail "$executable ($arch): cannot read build version ($build_info)"
        fi
        details=$(codesign -dvv --architecture $arch $bundle 2>&1) || { fail "$name ($arch): not signed"; signed_ok=0; continue; }
        signed_as=$(print -r -- $details | sed -n 's/^Identifier=//p')
        [[ $signed_as == "$expected" ]] || fail "$name ($arch): signed as '$signed_as', not $expected"
        print -r -- $details | grep '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime.*)' >/dev/null ||
            fail "$name ($arch): no hardened runtime ($(print -r -- $details | grep -o 'flags=[^ ]*'))"
        if (( release )) && [[ -n $team ]] &&
            ! problems=$(check_release_signature "$details" $team "$name ($arch)" 2>&1); then
            for line in ${(f)problems}; do fail "$line"; done
            signed_ok=0
        fi
    done
    # The text names the signer; this proves it: a Developer ID leaf from that team, chained to
    # Apple, so a self-made certificate with the same names cannot pass. `--verify` checks every
    # architecture.
    if (( release && signed_ok )) && [[ -n $team ]] &&
        ! codesign --verify --strict -R="$(developer_id_requirement $team)" $bundle 2>/dev/null; then
        fail "$name: not a Developer ID signature from team $team under Apple's root"
    fi
done

# Only the Settings helper draws device art (build-app.sh copies the silhouettes there) and holds
# the action packs catalogue: the menu bar app and the daemon's own resources must hold none.
settings_resources="$(component_path $app "$(settings_component)")/Contents/Resources"
if [[ ! -f $settings_resources/ActionPacks.json ]]; then
    fail "${settings_resources#$app/}/ActionPacks.json: missing action packs catalogue in Settings helper"
fi

for resources in "$(component_path $app "$(menu_component)")" $app/Contents/Resources; do
    [[ -d $resources ]] || continue
    stray=$(find $resources -path '*silhouettes*' -name '*.pdf' -print -quit)
    [[ -z $stray ]] || fail "${stray#$app/}: device art belongs to the Settings helper alone"
    stray_pack=$(find $resources -name 'ActionPacks.json' -print -quit)
    [[ -z $stray_pack ]] || fail "${stray_pack#$app/}: action packs catalogue belongs to the Settings helper alone"
done

(( failed == 0 )) || exit 1
print "verified $app ($app_version, build $app_build$( (( release )) && print ', release'))"

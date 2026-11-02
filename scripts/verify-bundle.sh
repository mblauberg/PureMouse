#!/bin/zsh
# Checks a signed PureMouse.app before anyone installs or ships it, and names every component that
# fails. For each bundle in lib.zsh's `components`: its Info.plist is present and valid, its
# identifier is the frozen label (in the plist and the signature), its signature verifies strictly
# and carries the hardened runtime, and its version matches the app's.
#
#   verify-bundle.sh <app> [--release]
#
#   --release  also: the version is a release version (X.Y.Z or X.Y.Z-rc.N), and when
#              PUREMOUSE_TEAM_ID is set (scripts/release.env, if present, sets it) every component
#              is signed by a Developer ID Application identity of that team. With no team ID only
#              the base checks run.
set -euo pipefail
source "${0:A:h}/lib.zsh"

app= release=0
for argument; do
    case $argument in
        --release) release=1 ;;
        -*) die "usage: verify-bundle.sh <app> [--release]" ;;
        *) app=$argument ;;
    esac
done
[[ -n $app && -d $app ]] || die "usage: verify-bundle.sh <app> [--release]"
if (( release )) && [[ -z ${PUREMOUSE_TEAM_ID:-} && -f $root/scripts/release.env ]]; then
    source $root/scripts/release.env
fi
team=${PUREMOUSE_TEAM_ID:-}

failed=0
fail() {
    print -u2 -- "FAIL $*"
    failed=1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" $1 2>/dev/null
}

app_version=$(plist_value $app/Contents/Info.plist CFBundleShortVersionString || true)
app_build=$(plist_value $app/Contents/Info.plist CFBundleVersion || true)
if (( release )) && ! release_version_ok "$app_version"; then
    fail "$app: version '$app_version' is not a release version (X.Y.Z or X.Y.Z-rc.N)"
fi

for component in $components; do
    expected=${component%%:*}
    bundle=${${:-$app/${component#*:}}%/.}
    name=${bundle:t}
    plist=$bundle/Contents/Info.plist
    if [[ ! -f $plist ]]; then
        fail "$name: no Contents/Info.plist"
        continue
    fi
    plutil -lint -s $plist || fail "$name: Info.plist does not parse"
    identifier=$(plist_value $plist CFBundleIdentifier || true)
    [[ $identifier == $expected ]] || fail "$name: CFBundleIdentifier is '$identifier', not $expected"
    for key in CFBundleShortVersionString:$app_version CFBundleVersion:$app_build; do
        value=$(plist_value $plist ${key%%:*} || true)
        [[ $value == ${key#*:} ]] || fail "$name: ${key%%:*} is '$value', not '${key#*:}' as in the app"
    done

    if ! codesign --verify --strict $bundle 2>/dev/null; then
        fail "$name: signature does not verify ($(codesign --verify --strict $bundle 2>&1 | tail -1))"
    fi
    details=$(codesign -dvv $bundle 2>&1) || { fail "$name: not signed"; continue; }
    signed_as=$(print -r -- $details | sed -n 's/^Identifier=//p')
    [[ $signed_as == $expected ]] || fail "$name: signed as '$signed_as', not $expected"
    print -r -- $details | grep '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime.*)' >/dev/null ||
        fail "$name: no hardened runtime ($(print -r -- $details | grep -o 'flags=[^ ]*'))"
    if (( release )) && [[ -n $team ]]; then
        if ! problems=$(check_release_signature "$details" $team $name 2>&1); then
            for line in ${(f)problems}; do fail "$line"; done
        # The text names the signer; this proves it: a Developer ID leaf from that team, chained to
        # Apple, so a self-made certificate with the same names cannot pass.
        elif ! codesign --verify --strict -R="$(developer_id_requirement $team)" $bundle 2>/dev/null; then
            fail "$name: not a Developer ID signature from team $team under Apple's root"
        fi
    fi
done

(( failed == 0 )) || exit 1
print "verified $app ($app_version, build $app_build$( (( release )) && print ', release'))"

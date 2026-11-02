#!/bin/zsh
# Makes the release dmg: a read-only compressed (ULFO) volume holding PureMouse.app and a link to
# /Applications to drag it onto, with no Finder styling. Signs the dmg when given an identity.
#
#   make-dmg.sh <app> <out.dmg> [--identity ID] [--timestamp]
#
#   --identity ID  sign the dmg with this code-signing identity (default and `-`: leave it unsigned,
#                  since an ad-hoc signature on a dmg proves nothing)
#   --timestamp    ask Apple's timestamp server for a secure timestamp (releases; needs the network)
set -euo pipefail
source "${0:A:h}/lib.zsh"

usage="usage: make-dmg.sh <app> <out.dmg> [--identity ID] [--timestamp]"
app= dmg= identity= timestamp=--timestamp=none
while (( $# )); do
    case $1 in
        --identity) (( $# >= 2 )) || die "--identity needs a value"; identity=$2; shift 2 ;;
        --timestamp) timestamp=--timestamp; shift ;;
        -*) die $usage ;;
        *)
            if [[ -z $app ]]; then app=$1
            elif [[ -z $dmg ]]; then dmg=$1
            else die $usage
            fi
            shift ;;
    esac
done
[[ -d $app && $dmg == *.dmg ]] || die $usage

stage=$(mktemp -d)
trap 'rm -rf $stage' EXIT
ditto $app $stage/PureMouse.app
ln -s /Applications $stage/Applications

# hdiutil sometimes fails with "Resource busy" on a machine that is busy indexing; it passes again.
rm -f $dmg
for attempt in 1 2 3; do
    hdiutil create -volname PureMouse -srcfolder $stage -fs HFS+ -format ULFO -ov $dmg >/dev/null && break
    rm -f $dmg
    (( attempt < 3 )) || die "hdiutil create failed three times"
    sleep 2
done

if [[ -n $identity && $identity != - ]]; then
    codesign --force --sign "$identity" $timestamp $dmg
fi
echo "made $dmg"

#!/bin/zsh
# Signs PureMouse.app and every bundle nested in it, innermost first (lib.zsh's `components`),
# without --deep, so each keeps its own identifier and the outer signature seals the inner ones.
# Every build gets the hardened runtime, whatever the identity: it is what notarisation needs, and
# signing ad hoc or self-signed with it shows any runtime problem long before a release does.
#
#   sign-bundle.sh <app> [--identity ID] [--timestamp]
#
#   --identity ID  a code-signing identity, or - for ad hoc; default as in lib.zsh's
#                  signing_identity (PUREMOUSE_SIGN_IDENTITY, Developer ID, PureMouse, ad hoc)
#   --timestamp    ask Apple's timestamp server for a secure timestamp (release builds; needs the
#                  network). Without it, builds sign with --timestamp=none.
set -euo pipefail
source "${0:A:h}/lib.zsh"

app= identity= timestamp=--timestamp=none
while (( $# )); do
    case $1 in
        --identity) (( $# >= 2 )) || die "--identity needs a value"; identity=$2; shift 2 ;;
        --timestamp) timestamp=--timestamp; shift ;;
        -*) die "usage: sign-bundle.sh <app> [--identity ID] [--timestamp]" ;;
        *) [[ -z $app ]] || die "one app at a time"; app=$1; shift ;;
    esac
done
[[ -n $app && -d $app ]] || die "usage: sign-bundle.sh <app> [--identity ID] [--timestamp]"
[[ -n $identity ]] || identity=$(signing_identity)
# An ad-hoc signature has no certificate for a timestamp to vouch for.
[[ $identity == - ]] && timestamp=--timestamp=none

for component in $components; do
    codesign --force --sign "$identity" --options runtime $timestamp \
        --identifier ${component%%:*} "${${:-$app/${component#*:}}%/.}"
done

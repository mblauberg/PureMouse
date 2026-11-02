#!/bin/zsh
# Fails when the installed bundle or the release dmg outgrows its published budget
# (scripts/size-budget.env). For an app, the installed size is the sum of the bytes of every file in
# it, as Finder counts it before block rounding. For a dmg, it is the size of the file. An
# INSTALLED_MAX_BYTES or DMG_MAX_BYTES already in the environment wins over the file.
#
#   check-size.sh <app | dmg>
set -euo pipefail
source "${0:A:h}/lib.zsh"

target=${1:-}
[[ -n $target && ( -d $target || -f $target ) ]] || die "usage: check-size.sh <app | dmg>"
load_env_file $root/scripts/size-budget.env

if [[ -d $target ]]; then
    kind=installed variable=INSTALLED_MAX_BYTES limit=$INSTALLED_MAX_BYTES
    size=$(find $target -type f -exec stat -f %z {} + | awk '{ sum += $1 } END { print sum + 0 }')
else
    kind=dmg variable=DMG_MAX_BYTES limit=$DMG_MAX_BYTES
    size=$(stat -f %z $target)
fi
[[ $limit == <-> ]] || die "$variable is not a number: '$limit'"

megabytes() { printf '%.1f MB' $(( $1 / 1e6 )); }
summary="$kind size $size bytes ($(megabytes $size)), allowed $limit bytes ($(megabytes $limit))"
if (( size > limit )); then
    print -u2 -- "FAIL $target: $summary"
    print -u2 -- "Shrink it, or raise $variable in scripts/size-budget.env in a reviewed change."
    exit 1
fi
print -- "ok $target: $summary"

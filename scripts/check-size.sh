#!/bin/zsh
# Fails when the installed bundle outgrows its published budget (scripts/size-budget.env).
# The installed size is the sum of the bytes of every file in the app, as Finder counts it before
# block rounding. An INSTALLED_MAX_BYTES already in the environment wins over the file.
#
#   check-size.sh <app>
set -euo pipefail
source "${0:A:h}/lib.zsh"

app=${1:-}
[[ -n $app && -d $app ]] || die "usage: check-size.sh <app>"
if [[ -z ${INSTALLED_MAX_BYTES:-} ]]; then
    source $root/scripts/size-budget.env
fi
[[ $INSTALLED_MAX_BYTES == <-> ]] || die "INSTALLED_MAX_BYTES is not a number: '$INSTALLED_MAX_BYTES'"

installed=$(find $app -type f -exec stat -f %z {} + | awk '{ sum += $1 } END { print sum + 0 }')
megabytes() { printf '%.1f MB' $(( $1 / 1e6 )); }
summary="installed size $installed bytes ($(megabytes $installed)), allowed $INSTALLED_MAX_BYTES bytes ($(megabytes $INSTALLED_MAX_BYTES))"
if (( installed > INSTALLED_MAX_BYTES )); then
    print -u2 -- "FAIL $app: $summary"
    print -u2 -- "Shrink the bundle, or raise INSTALLED_MAX_BYTES in scripts/size-budget.env in a reviewed change."
    exit 1
fi
print -- "ok $app: $summary"

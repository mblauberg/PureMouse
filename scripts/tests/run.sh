#!/bin/zsh
# Tests for the build, sign, verify and size scripts. Each test_*.zsh file defines `test_*`
# functions; each runs in its own subshell with a fresh $tmp, and a non-zero status fails it.
#
#   scripts/tests/run.sh [name-filter]
#
# Tests that need a real bundle use PUREMOUSE_TEST_APP, else .build/app/PureMouse.app, and are
# skipped when there is none (CI builds one first). The rest build a stand-in bundle around
# /usr/bin/true, so they need no Swift build.
set -uo pipefail
here=${0:A:h}
source $here/../lib.zsh
source $here/helpers.zsh
for file in $here/test_*.zsh; do source $file; done

filter=${1:-}
integer passed=0 failed=0 skipped=0
for name in ${(ok)functions[(I)test_*]}; do
    [[ -z $filter || $name == *$filter* ]] || continue
    tmp=$(mktemp -d)
    output=$( (set -e; cd $root; $name) 2>&1 )
    case $? in
        0) passed+=1; print "ok   $name" ;;
        77) skipped+=1; print "skip $name: ${output##*$'\n'}" ;;
        *) failed+=1; print "FAIL $name"; print -r -- $output | sed 's/^/     /' ;;
    esac
    rm -rf $tmp
done
print "$passed passed, $failed failed, $skipped skipped"
(( passed + failed > 0 )) || { print "no tests ran"; exit 1; }
(( failed == 0 ))

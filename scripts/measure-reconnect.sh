#!/bin/zsh
# Times how long settings take to come back after a wake, a reconnect or a host switch-back, and
# fails above 2 seconds. Two legs (docs/development.md, "Reconnect rig"):
#
#   fake      N cycles each of a wake, a reconnect and a host switch-back against a fake device, on the
#             daemon's live retry schedule, timed from the moment the fake starts answering to the
#             session's applied state. Runs `swift test --filter ReconnectRigTests`, touches no mouse,
#             no daemon and no file outside .build; safe anywhere.
#   hardware  N cycles on a real mouse, owner assisted. Watches the installed daemon's status.json and
#             reports the time from a device going to "applying" to "applied". Run it on the owner's
#             Mac with the daemon running; it only reads status.json and starts nothing.
#
#   ./scripts/measure-reconnect.sh fake [--cycles N]          (default 10)
#   ./scripts/measure-reconnect.sh hardware [--cycles N]      (default 5)
#   ./scripts/measure-reconnect.sh summarise FILE             (a saved run's `rig <kind> <cycle> <ms>` lines)
#
# Exit status: 0 every cycle within the limit, 1 a cycle above it, 2 the rig itself failed.
set -euo pipefail
zmodload zsh/datetime
cd "${0:A:h}/.."

limit_ms=2000
fail() { print -u2 "measure-reconnect: $*"; exit 2 }

# Reads `rig <kind> <cycle> <ms>` lines on stdin; prints a table and returns 1 above the limit.
summarise() {
    awk -v limit=$limit_ms '
    $1 == "rig" && $4 ~ /^[0-9]+$/ { n[$2]++; v[$2, n[$2]] = $4 + 0; if ($4 + 0 > worst[$2]) worst[$2] = $4 + 0; total++ }
    END {
        if (!total) { print "measure-reconnect: no cycles were recorded" > "/dev/stderr"; exit 2 }
        printf "%-12s %6s %8s %8s\n", "kind", "cycles", "median", "worst"
        bad = 0
        for (k in n) {
            m = n[k]
            for (i = 1; i <= m; i++) a[i] = v[k, i]
            for (i = 2; i <= m; i++) { x = a[i]; j = i - 1; while (j >= 1 && a[j] > x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
            med = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
            printf "%-12s %6d %6d ms %6d ms\n", k, m, med, worst[k]
            if (worst[k] > limit) bad = 1
        }
        if (bad) { printf "FAIL: a cycle took more than %d ms\n", limit; exit 1 }
        printf "ok: every cycle within %d ms\n", limit
    }'
}

cycles_arg() {
    local value=$1
    [[ $value == <-> && $value -gt 0 ]] || fail "--cycles needs a positive whole number"
    print -r -- $value
}

run_fake() {
    local cycles=$1 out
    out=$(PUREMOUSE_RIG_CYCLES=$cycles swift test --filter ReconnectRigTests 2>&1) || {
        print -r -- $out | tail -40 >&2
        print -u2 "measure-reconnect: the fake leg's tests failed"
        # A cycle over the limit fails an expectation; the table below says which.
        print -r -- $out | grep '^rig ' | summarise || true
        exit 1
    }
    print -r -- $out | grep '^rig ' | tee ${PUREMOUSE_RIG_TSV:-/dev/null} | summarise
}

# The state of the first two devices in status.json, space separated ("applying applied").
device_states() {
    local file=$1 i state out=()
    for i in 0 1; do
        state=$(plutil -extract devices.$i.applied.state raw -o - $file 2>/dev/null) || state=-
        out+=($state)
    done
    print -r -- "${out[*]}"
}

run_hardware() {
    local cycles=$1 status=${PUREMOUSE_COMPANION_DIR:-$HOME/Library/Application Support/PureMouse}/status.json
    [[ -f $status ]] || fail "no status.json at $status: is the daemon running?"
    pgrep -x puremouse >/dev/null || fail "no puremouse daemon found: start it first"
    print "Hardware leg, $cycles cycles. Each cycle: when asked, wake the Mac from sleep, or switch the"
    print "mouse off and on, or switch it to another Mac and back. The time is from the device going to"
    print "\"applying\" to \"applied\" in status.json, so it includes the mouse waking."
    local c start now before after i results=()
    for (( c = 1; c <= cycles; c++ )); do
        print -n "cycle $c: trigger it now (the rig waits 60 s)... "
        before=$(device_states $status)
        start=
        local deadline=$(( EPOCHREALTIME + 60 )) seen=
        while (( EPOCHREALTIME < deadline )); do
            after=$(device_states $status)
            if [[ -z $start && $after == *applying* ]]; then start=$EPOCHREALTIME; fi
            if [[ -n $start && $after != *applying* && $after == *applied* ]]; then
                now=$EPOCHREALTIME
                seen=$(( (now - start) * 1000 ))
                break
            fi
            sleep 0.05
        done
        if [[ -z $seen ]]; then print "nothing seen"; fail "cycle $c: no applying then applied within 60 s"; fi
        printf '%d ms\n' $seen
        results+=("rig hardware $c ${seen%.*}")
    done
    print -l -- $results | summarise
}

(( $# >= 1 )) || fail "usage: measure-reconnect.sh fake|hardware [--cycles N] | summarise FILE"
mode=$1; shift
case $mode in
    summarise)
        (( $# == 1 )) && [[ -f $1 ]] || fail "summarise needs a file"
        summarise < $1 ;;
    fake|hardware)
        cycles=$([[ $mode == fake ]] && print 10 || print 5)
        while (( $# )); do
            case $1 in
                --cycles) (( $# >= 2 )) || fail "--cycles needs a value"; cycles=$(cycles_arg $2); shift 2 ;;
                *) fail "unknown argument $1" ;;
            esac
        done
        run_$mode $cycles ;;
    *) fail "unknown mode $mode" ;;
esac

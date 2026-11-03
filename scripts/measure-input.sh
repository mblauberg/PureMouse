#!/bin/zsh
# Measure the daemon's CPU time and idle wakeups in still and moving windows.
# Run this on a Mac with the daemon already running; it does not change daemon or mouse state.
# Usage: scripts/measure-input.sh [seconds]
set -euo pipefail

usage() {
    print -u2 "usage: ${0:t} [positive whole-number seconds]"
    exit 2
}
fail() {
    print -u2 "measure-input: $*"
    exit ${2:-2}
}

(( $# <= 1 )) || usage
duration=${1:-20}
[[ $duration == <-> && $duration -gt 0 ]] || fail "duration must be a positive whole number of seconds"

find_daemon() {
    local output pgrep_status
    output=$(pgrep -x puremouse 2>/dev/null) && pgrep_status=0 || pgrep_status=$?
    (( pgrep_status == 0 )) || {
        (( pgrep_status == 1 )) && fail "no puremouse daemon found" 1
        fail "pgrep could not inspect processes (exit $pgrep_status)"
    }
    local -a pids
    pids=(${(f)output})
    (( ${#pids} == 1 )) || {
        (( ${#pids} == 0 )) && fail "no puremouse daemon found" 1
        fail "multiple puremouse daemons found (${#pids})"
    }
    [[ ${pids[1]} == <-> ]] || fail "pgrep returned a malformed PID: ${pids[1]}"
    print -r -- ${pids[1]}
}

parse_top() {
    local file=$1 pid=$2 expected=$(( duration + 3 ))
    awk -v wanted="$pid" -v expected="$expected" '
    function bad(message) { if (!fatal) print "measure-input: malformed top sample: " message > "/dev/stderr"; fatal=1; exit 2 }
    function parse_time(value, parts, n, sec) {
        n = split(value, parts, ":")
        if (n == 2) {
            if (parts[1] !~ /^[0-9]+$/ || parts[2] !~ /^[0-9]+([.][0-9]+)?$/ || parts[2] >= 60) return -1
            return parts[1] * 60 + parts[2]
        }
        if (n == 3) {
            if (parts[1] !~ /^[0-9]+$/ || parts[2] !~ /^[0-9]+$/ || parts[2] >= 60 || parts[3] !~ /^[0-9]+([.][0-9]+)?$/ || parts[3] >= 60) return -1
            return parts[1] * 3600 + parts[2] * 60 + parts[3]
        }
        return -1
    }
    function numeric(value) { return value ~ /^[0-9]+([.][0-9]+)?$/ }
    BEGIN { samples=0; fatal=0 }
    {
        if ($1 == "PID") {
            pidcol=cpucol=wakecol=timecol=0
            for (i=1; i<=NF; i++) {
                key=toupper($i)
                if (key == "PID") pidcol=i
                if (key == "%CPU" || key == "CPU") cpucol=i
                if (key == "IDLEW") wakecol=i
                if (key == "TIME") timecol=i
            }
            if (!pidcol || !cpucol || !wakecol || !timecol) bad("top header lacks PID, CPU, IDLEW or TIME")
            have_header=1
            next
        }
        if (have_header && $1 ~ /^[0-9]+$/) {
            if (NF < pidcol || NF < cpucol || NF < wakecol || NF < timecol) bad("truncated process row")
            if ($pidcol != wanted) bad("top reported PID " $pidcol ", expected " wanted)
            cpu=$cpucol; sub(/%$/, "", cpu)
            wake=$wakecol
            elapsed=parse_time($timecol)
            if (!numeric(wake) || elapsed < 0) bad("invalid IDLEW or TIME value")
            samples++
            if (samples > 1 && (wake < previous_wake || elapsed < previous_time)) bad("cumulative counter moved backwards")
            # The first three samples warm up CPU accounting and establish cumulative counter baselines.
            if (samples == 3) {
                first_time=elapsed
                previous_wake=wake
            } else if (samples > 3) {
                if (!numeric(cpu)) bad("invalid CPU value " $cpucol)
                total_wakes += wake - previous_wake
                total_cpu += cpu + 0
                cpu_ms = (elapsed - first_time) * 1000
                intervals++
                previous_wake=wake
            }
            previous_time=elapsed
        }
    }
    END {
        if (fatal) exit 2
        if (samples != expected) bad("expected " expected " process samples, got " samples)
        if (intervals != expected - 3 || intervals < 1 || cpu_ms < 0) bad("not enough valid samples after three warm-up samples")
        printf "%.2f\t%.2f\t%.0f\t%d\n", total_wakes / intervals, total_cpu / intervals, cpu_ms, intervals
    }' "$file"
}

sample_window() {
    local label=$1 pid=$2 summary
    if [[ $label == still ]]; then
        print "\nStill window: keep the mouse still, then press Return to start (${duration}s)."
    else
        print "\nMoving window: move the mouse normally, then press Return to start (${duration}s)."
    fi
    read -r _ || true
    local topfile=${TMPDIR:-/tmp}/puremouse-top.$$.${label// /-}
    if ! top -l $(( duration + 3 )) -s 1 -pid "$pid" -stats pid,cpu,idlew,time >| "$topfile"; then
        rm -f "$topfile"
        fail "top failed while measuring the $label window"
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$topfile"
        fail "puremouse process $pid exited during the $label window"
    fi
    summary=$(parse_top "$topfile" "$pid") || { rm -f "$topfile"; exit 2; }
    rm -f "$topfile"
    local wakeups=${summary%%$'\t'*}
    summary=${summary#*$'\t'}
    local cpu=${summary%%$'\t'*}
    summary=${summary#*$'\t'}
    local cpu_ms=${summary%%$'\t'*} count=${summary##*$'\t'}
    print "$label: PID $pid, duration ${duration}s, $count samples; mean idle wakeups/s $wakeups, mean CPU $cpu%, CPU ${cpu_ms}ms"
}

pid=$(find_daemon)
# Confirm top accepts the requested fields and can report this PID before asking the user to measure.
probe=${TMPDIR:-/tmp}/puremouse-top-probe.$$
if ! top -l 1 -s 1 -pid "$pid" -stats pid,cpu,idlew,time >| "$probe"; then
    rm -f "$probe"
    fail "top could not read PID $pid or does not support the requested fields"
fi
if ! grep -Eq "^[[:space:]]*PID[[:space:]]+%?CPU[[:space:]]+IDLEW[[:space:]]+TIME([[:space:]]|$)" "$probe"; then
    rm -f "$probe"
    fail "top returned unexpected fields; expected PID, CPU, IDLEW and TIME"
fi
rm -f "$probe"

sample_window still "$pid"
sample_window moving "$pid"

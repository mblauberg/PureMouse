#!/bin/zsh
# Measures the menu bar app's memory footprint and checks it against scripts/measure-menu.budgets.
# Run it on a spare Mac with a logged-in GUI session and nobody using it, never on a Mac whose
# PureMouse you rely on (it is isolated from the installed one, but it does open menus and windows).
# Usage and scenarios: docs/development.md ("Footprint rig").
#
#   ./scripts/measure-menu.sh [--runs N] [--blocks] [--no-build] [--budgets FILE] [--tsv FILE]
#                             [--write-budgets] [--keep] [--plugin-path DIR] [--env NAME=value]...
#   --env NAME=value  adds a variable to the menu's environment (e.g. MallocSpaceEfficient=1), to compare
#
# A Mac with only the command line tools cannot expand SwiftUI's @State (the SDK's SwiftUIMacros
# plugin ships with Xcode). Copy Xcode's libSwiftUIMacros.dylib (Xcode.app/Contents/Developer/
# Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/) into a directory of its own
# there and pass it as --plugin-path DIR (or PUREMOUSE_RIG_PLUGIN_PATH). The compiler must be the
# same release as Xcode's.
#
# Exit status: 0 every budget met, 1 a budget exceeded, 2 the rig itself failed.
#
# How it stays apart from the installed app: the menu is a release build with -DDEVHOOKS, in a
# bundle of its own (io.github.mblauberg.puremouse.menu.rig) under .build/rig, started with
# PUREMOUSE_COMPANION_DIR, PUREMOUSE_CONFIG and PUREMOUSE_DAEMON pointing into a throwaway
# fixture directory. A stub process stands in for the daemon. The companion directory also renames
# the doorbells (Companion.doorbell), so nothing it rings reaches the installed app. The script
# only reads the installed agents' pids (launchctl print) before and after, and fails if either changed.
set -euo pipefail
zmodload zsh/datetime
# An unexpected command failure is a harness error (2), not a budget failure (1).
TRAPZERR() { exit 2 }
source "${0:A:h}/lib.zsh"
cd "${0:A:h}/.."

runs=5
blocks=0
build=1
write_budgets=0
keep=0
rig_env=()
plugin_path=${PUREMOUSE_RIG_PLUGIN_PATH:-}
budgets=scripts/measure-menu.budgets
tsv=
while (( $# )); do
    case $1 in
        --runs|--budgets|--tsv|--plugin-path|--env) (( $# >= 2 )) || { print -u2 "$1 needs a value"; exit 2 } ;;
    esac
    case $1 in
        --runs) runs=$2; shift ;;
        --blocks) blocks=1 ;;
        --no-build) build=0 ;;
        --budgets) budgets=$2; shift ;;
        --tsv) tsv=$2; shift ;;
        --write-budgets) write_budgets=1 ;;
        --keep) keep=1 ;;
        --plugin-path) plugin_path=$2; shift ;;
        --env) rig_env+=($2); shift ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' $0; exit 0 ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
    shift
done
[[ $runs == <-> && $runs -ge 1 ]] || { print -u2 "--runs needs a number"; exit 2 }

daemon_label=$label
rig_label=$menu_label.rig
scratch=$PWD/.build/rig
app=$scratch/PureMouse\ Rig.app
exe=$app/Contents/MacOS/PureMouseMenu
settle=1.5          # seconds between an action and the reading after it
export HOME=${HOME:?}

fail() { print -u2 "measure-menu: $*"; exit 2 }
for tool in footprint notifyutil codesign swift launchctl; do
    command -v $tool >/dev/null || fail "$tool not found"
done
[[ $(uname) == Darwin ]] || fail "macOS only"

# Every limit is a whole number, and the scenarios a change to the menu could regress each have one:
# a gate must not pass for lack of a limit.
check_budgets() {
    [[ -f $budgets ]] || fail "no budgets file at $budgets"
    local name limit
    while IFS=$'\t' read -r name limit || [[ -n $name ]]; do  # a last line without a newline counts too
        [[ $name == \#* || -z $name ]] && continue
        [[ $limit == <-> ]] || fail "$budgets: the limit for '$name' is '$limit', not a whole number"
    done < $budgets
    for name in fresh open-1 open-10 doorbells-200; do
        [[ $(awk -F'\t' -v s=$name '$1 == s { print $2 }' $budgets) == <-> ]] \
            || fail "$budgets needs exactly one whole-number limit for '$name'"
    done
}
(( write_budgets )) || check_budgets

# --- The installed agents: only ever read -------------------------------------------------------
installed_pid() {
    { launchctl print gui/$UID/$1 2>/dev/null || true; } | awk '$1 == "pid" && $2 == "=" { print $3; found = 1 } END { if (!found) print "none" }'
}
installed_before="$(installed_pid $menu_label) $(installed_pid $daemon_label)"

# --- Build ---------------------------------------------------------------------------------------
mkdir -p $scratch
plugin_flags=()
[[ -z $plugin_path ]] || plugin_flags=(-Xswiftc -plugin-path -Xswiftc $plugin_path)
if (( build )); then
    print "building the release menu with -DDEVHOOKS (scratch: $scratch/build)"
    swift build -c release --product PureMouseMenu -Xswiftc -DDEVHOOKS $plugin_flags --scratch-path $scratch/build >$scratch/build.log 2>&1 \
        || {
            grep -q "plugin for module 'SwiftUIMacros' not found" $scratch/build.log \
                && print -u2 "this Mac lacks Xcode's SwiftUIMacros plugin: see --plugin-path in the script's header"
            grep error: $scratch/build.log | head -5 >&2
            fail "build failed (log: $scratch/build.log)"
        }
fi
bin=$(swift build -c release --product PureMouseMenu --scratch-path $scratch/build --show-bin-path)
[[ -x $bin/PureMouseMenu ]] || fail "no built menu at $bin (run without --no-build)"

rm -rf $app
make_menu_bundle $bin/PureMouseMenu $app $rig_label rig 0
codesign --force --sign - --identifier $rig_label $app >/dev/null 2>&1 || fail "could not sign the rig bundle"

# The Settings helper, once it exists, is built and measured too.
helper=
if grep -q 'PureMouseSettings' Package.swift; then
    if (( build )); then
        swift build -c release --product PureMouseSettings $plugin_flags --scratch-path $scratch/build >>$scratch/build.log 2>&1 \
            || fail "helper build failed (log: $scratch/build.log)"
    fi
    helper=$bin/PureMouseSettings
fi

# --- Fixture and process control -----------------------------------------------------------------
results=$scratch/results; mkdir -p $results
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $tsv ]] || tsv=$results/measure-menu-$stamp.tsv
printf 'scenario\trun\tvalue\tpeak\tunit\n' > $tsv

fixtures=()
menu_pid=
stub_pid=
cleanup() {
    stop_menu
    if (( ! keep && ${#fixtures} )); then rm -rf $fixtures; fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

stop_menu() {
    local pid i
    for pid in $menu_pid $stub_pid; do
        kill $pid 2>/dev/null || continue
        for i in {1..50}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
        kill -9 $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
    done
    menu_pid=; stub_pid=
}

write_status() {  # battery percent
    cat > $fx/status.json.tmp <<JSON
{
  "schema": 1, "pid": $stub_pid, "startedAt": "2026-01-01T00:00:00Z", "version": "rig",
  "running": true, "paused": false,
  "permissions": { "accessibility": true, "inputMonitoring": true },
  "logiOptionsRunning": false,
  "config": { "path": "$fx/config.json" },
  "devices": [{
    "id": "0-1", "name": "MX Master 3S", "connection": "receiver", "online": true,
    "battery": { "percent": $1, "level": "good", "charging": false },
    "dpi": 1600, "dpiSteps": [800, 1600, 3200], "wheelMode": "ratchet",
    "hasSmartShift": true, "hasThumbWheel": true,
    "controls": [{ "cid": 83, "name": "back" }, { "cid": 86, "name": "forward" }, { "cid": 195, "name": "gesture" }]
  }]
}
JSON
    mv -f $fx/status.json.tmp $fx/status.json
}

# start_menu [VAR=value ...]: a fresh fixture, a stub daemon and the rig menu, ready for commands.
start_menu() {
    # The rig's own preferences domain (Settings' pane and frame) starts empty each time: left to
    # build up, a state like it once added 4 MB to every launch that followed.
    defaults delete $rig_label 2>/dev/null || true
    fx=$(mktemp -d "${TMPDIR:-/tmp}/puremouse-rig.XXXXXX")
    fx=${fx:A}
    fixtures+=($fx)
    cp config.example.json $fx/config.json
    print '#!/bin/sh\nexit 0' > $fx/daemon; chmod +x $fx/daemon
    sleep 86400 &
    stub_pid=$!
    write_status 80
    # Malloc*, DYLD_* and the like in the caller's shell would change what is measured.
    local scrub=() v
    for v in ${(k)parameters[(R)*export*]}; do if [[ $v == (Malloc*|DYLD_*|NSZombie*|OS_ACTIVITY_*|CFNETWORK_*) ]]; then scrub+=(-u $v); fi; done
    env -u XPC_SERVICE_NAME $scrub $rig_env "$@" PUREMOUSE_COMPANION_DIR=$fx PUREMOUSE_CONFIG=$fx/config.json PUREMOUSE_DAEMON=$fx/daemon \
        $exe --login >$fx/menu.log 2>&1 &
    menu_pid=$!
    started=$EPOCHREALTIME
    local i
    for i in {1..200}; do
        [[ -s $fx/rig-ready ]] && break
        kill -0 $menu_pid 2>/dev/null || { cat $fx/menu.log >&2; fail "the rig menu exited at launch" }
        sleep 0.1
    done
    [[ -s $fx/rig-ready ]] || fail "the rig menu never reported ready (no window server session? log: $fx/menu.log)"
    rig_bell=$(awk '$1 == "rig" { print $2 }' $fx/rig-ready)
    status_bell=$(awk '$1 == "status" { print $2 }' $fx/rig-ready)
    [[ -n $rig_bell && -n $status_bell && $rig_bell == io.github.mblauberg.puremouse.rig.* \
        && $status_bell == io.github.mblauberg.puremouse.status.* ]] \
        || fail "the rig menu did not use hashed doorbells ($fx/rig-ready)"
    serial=0
    sleep 3
}

# rig VERB: asks the menu to do it and waits until it says it has.
rig() {
    serial=$(( serial + 1 ))
    print -r -- "$serial $1" > $fx/rig-command.tmp
    mv -f $fx/rig-command.tmp $fx/rig-command
    notifyutil -p $rig_bell
    local i
    for i in {1..300}; do
        if [[ -f $fx/rig-ack && $(<$fx/rig-ack) == $serial ]]; then return 0; fi
        kill -0 $menu_pid 2>/dev/null || { tail -5 $fx/menu.log >&2; fail "the rig menu exited during '$1'" }
        sleep 0.1
    done
    fail "the rig menu did not answer '$1' in 30 s"
}

# sample SCENARIO RUN: the menu's footprint now, appended to the TSV.
sample() {
    local out fp peak
    out=$(footprint -f bytes --noCategories $menu_pid 2>&1) || fail "footprint failed: $out"
    fp=$(print -r -- $out | awk '$1 == "phys_footprint:" { print $2 }')
    peak=$(print -r -- $out | awk '$1 == "phys_footprint_peak:" { print $2 }')
    [[ $fp == <-> && $peak == <-> ]] || fail "could not read footprint for pid $menu_pid: $out"
    printf '%s\t%s\t%.2f\t%.2f\tMB\n' $1 $2 $(( fp / 1048576.0 )) $(( peak / 1048576.0 )) >> $tsv
}

# --- Scenarios (one run each) --------------------------------------------------------------------
run_menu_opens() {  # fresh, then after 1, 3 and 10 opens of the menu
    start_menu
    sleep $settle; sample fresh $1
    rig menu; sleep $settle; sample open-1 $1
    rig menu; rig menu; sleep $settle; sample open-3 $1
    local i; for i in {4..10}; do rig menu; done
    sleep $settle; sample open-10 $1
    stop_menu
}

run_doorbells() {  # 200 status doorbells, the status changing each time
    start_menu
    local i
    for i in {1..200}; do
        write_status $(( 50 + i % 40 ))
        notifyutil -p $status_bell
        sleep 0.01  # posts sent back to back can coalesce into one
    done
    sleep $settle; sample doorbells-200 $1
    stop_menu
}

run_settings() {  # Settings in the menu's own process (until the helper replaces it)
    start_menu
    rig settings; sleep 2; sample settings-open $1
    rig settings-close
    # The close is followed by malloc_zone_pressure_relief, which waits until the process is 11 s old.
    while (( EPOCHREALTIME - started < 13 )); do sleep 0.5; done
    rig relief
    sleep $settle; sample settings-closed $1
    stop_menu
}

run_helper() {  # only with a built helper: the menu's footprint while it is open and after, and its cold start
    start_menu
    local asked=$EPOCHREALTIME stamped
    rig settings
    for i in {1..100}; do [[ -e $fx/settings-visible ]] && break; sleep 0.1; done
    [[ -e $fx/settings-visible ]] || fail "the helper never wrote $fx/settings-visible"
    stamped=$(stat -f %Fm $fx/settings-visible)
    printf 'helper-cold-start\t%s\t%.2f\t0\tms\n' $1 $(( (stamped - asked) * 1000.0 )) >> $tsv
    sleep 2; sample helper-open $1
    rig settings-close; sleep 2; sample helper-closed $1
    stop_menu
}

for run in {1..$runs}; do
    print "run $run of $runs"
    run_menu_opens $run
    run_doorbells $run
    run_settings $run
    if [[ -n $helper ]]; then run_helper $run; fi
done

# --- --blocks: which allocations does opening the menu leave behind --------------------------------
if (( blocks )); then
    print "blocks: 30 menu opens under MallocStackLogging=1"
    command -v heap >/dev/null && command -v malloc_history >/dev/null || fail "heap and malloc_history are needed for --blocks"
    start_menu MallocStackLogging=1
    for i in {1..30}; do rig menu; done
    sleep $settle
    blocks_dir=$results/blocks-$stamp; mkdir -p $blocks_dir
    heap $menu_pid -addresses=all > $blocks_dir/heap.txt 2>&1 || fail "heap failed (output: $blocks_dir/heap.txt)"
    grep -q '^0x[0-9a-f]*:' $blocks_dir/heap.txt || fail "heap listed no blocks (output: $blocks_dir/heap.txt)"
    # 272 KB is 278528 bytes: the size of the blocks the earlier diagnosis could not place
    # (PUREMOUSE_RIG_BLOCK_BYTES picks another size to look for). Lines read "0x...: type in zone Z (N bytes)".
    size=${PUREMOUSE_RIG_BLOCK_BYTES:-278528}
    awk -v size=$size '/^0x[0-9a-f]+:/ && index($0, "(" size " bytes)") { sub(":", "", $1); print $1 }' $blocks_dir/heap.txt > $blocks_dir/blocks.txt || true
    count=$(wc -l < $blocks_dir/blocks.txt | tr -d ' ')
    largest=$(awk '/^0x[0-9a-f]+:/ { if (match($0, /\([0-9]+ bytes\)/)) { n = substr($0, RSTART + 1, RLENGTH - 8) + 0; if (n > m) m = n } } END { print m + 0 }' $blocks_dir/heap.txt)
    print "  blocks of $size bytes live after 30 opens: $count; the largest live block is $largest bytes (heap output in $blocks_dir)"
    if (( count > 0 )); then
        head -3 $blocks_dir/blocks.txt | while read -r address; do
            malloc_history $menu_pid $address > $blocks_dir/history-$address.txt 2>&1 || true
            print "  owner of $address:"
            sed -n '1,14p' $blocks_dir/history-$address.txt | cut -c1-200 | sed 's/^/    /'
            print "    (full history: $blocks_dir/history-$address.txt)"
        done
    else
        print "  not reproduced: no live block of $size bytes"
    fi
    stop_menu
fi

# --- Table and budgets -----------------------------------------------------------------------------
installed_after="$(installed_pid $menu_label) $(installed_pid $daemon_label)"
[[ $installed_before == $installed_after ]] \
    || fail "the installed agents changed while the rig ran (menu and daemon pids: $installed_before, then $installed_after)"

# scenario  median  min  max, in first-seen order. Medians of the footprint column.
summary=$(awk -F'\t' '
    NR == 1 { next }
    { if (!($1 in n)) order[++count] = $1; v[$1, ++n[$1]] = $3; unit[$1] = $5 }
    END {
        for (i = 1; i <= count; i++) {
            s = order[i]; m = n[s]
            for (a = 1; a <= m; a++) x[a] = v[s, a] + 0
            for (a = 2; a <= m; a++) { t = x[a]; b = a - 1; while (b >= 1 && x[b] > t) { x[b + 1] = x[b]; b-- } x[b + 1] = t }
            med = (m % 2) ? x[(m + 1) / 2] : (x[m / 2] + x[m / 2 + 1]) / 2
            printf "%s\t%.2f\t%.2f\t%.2f\t%d\t%s\n", s, med, x[1], x[m], m, unit[s]
        }
    }' $tsv)

if (( write_budgets )); then
    # The median plus 2 MB, rounded up, for the scenarios a change to the menu could regress; the
    # others (open-3, Settings in the menu's process, the helper) are reported only.
    { print "# scenario<TAB>limit in MB: a median above it fails scripts/measure-menu.sh. Written by --write-budgets from the"
      print "# medians of $runs runs on macOS $(sw_vers -productVersion), $(date +%Y-%m-%d), plus 2 MB rounded up; lower them when a change earns it."
      print -r -- $summary | awk -F'\t' '$1 ~ /^(fresh|open-1|open-10|doorbells-200)$/ { printf "%s\t%d\n", $1, ($2 + 2 == int($2 + 2)) ? $2 + 2 : int($2 + 2) + 1 }'; } > $budgets
    print "wrote $budgets"
fi
check_budgets

print
printf '%-22s %8s %8s %8s %8s   %s\n' scenario median min max budget result
verdict_code=0
exceeded=()
while IFS=$'\t' read -r name median low high n unit; do
    limit=$(awk -F'\t' -v s=$name '$1 == s { print $2 }' $budgets)
    verdict=
    if [[ -n $limit ]]; then
        if (( median > limit )); then
            verdict="OVER"; verdict_code=1; exceeded+=("$name: median $median $unit exceeds budget $limit $unit")
        else
            verdict=ok
        fi
    fi
    printf '%-22s %8s %8s %8s %8s   %s\n' $name $median $low $high "${limit:--}" $verdict
done <<< $summary
if [[ -z $helper ]]; then
    for name in helper-open helper-closed helper-cold-start; do
        printf '%-22s %s\n' $name "helper not built"
    done
fi
print
print "unit: MB of physical footprint (footprint(1)), median of $runs; macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
(( ${#rig_env} )) && print "menu environment: $rig_env"
print "samples: $tsv"
print "installed menu and daemon pids before and after: $installed_before / $installed_after"
for line in $exceeded; do print -u2 "BUDGET EXCEEDED  $line"; done
exit $verdict_code

#!/bin/zsh
# Runs the Settings helper's accessibility dump and its captures over every pane, sheet and dev hook
# in the matrix below, each with one fixture: one mouse, two mice, no mouse, paused, off. Light and
# dark captures for the rows that take them. Builds nothing: give it a debug build of
# PureMouseSettings (`swift build` makes it at .build/debug/PureMouseSettings). Each run is bounded:
# it is killed after --timeout seconds and reported as hung.
#
# Every run is sandboxed. Before it runs anything, the script points HOME, CFFIXED_USER_HOME,
# PUREMOUSE_CONFIG, PUREMOUSE_DAEMON and PUREMOUSE_COMPANION_DIR into a temporary folder, and it
# refuses (exit 2) if an inherited PUREMOUSE_CONFIG or the --out folder would resolve under the real
# ~/.config/puremouse. The daemon is a stub, status.json is the fixture, and the daemon's pid is a
# `sleep` that the script starts and kills. No live config, installed agent or running daemon is
# touched.
#
#   scripts/ui-matrix.sh [--binary PATH] [--out DIR] [--only NAME] [--timeout SECONDS]
#
#   --binary   the PureMouseSettings debug build (default .build/debug/PureMouseSettings)
#   --out      a new or empty folder for the captures, logs and summary.txt (default: a new folder
#              under $TMPDIR, named with the time)
#   --only     a matrix row or a fixture, by name: that row with every fixture, or that fixture with
#              every row
#   --timeout  seconds a run may take before it is killed and reported as hung (default 120)
#
# Output, per row and fixture: <row>.<fixture>.ax.txt (the dump); for the rows that take captures,
# <row>.<fixture>.<light|dark>.png and its .log, and <...>-sheet.png where the row opens a sheet.
# summary.txt lists every run and its result.
#
# Exit status: 0 every run clean; 1 a dump with a finding, a hung run, a failed run or a missing
# capture; 2 a usage error or the config guard. Run it on the spare Mac only (AGENTS.md, hard rules):
# it opens PureMouse Settings windows and captures them.
set -uo pipefail
root=${0:A:h:h}

# The matrix. One row per screen the dev hooks reach: its name, `shots` (dumped, then captured in
# light and dark) or `ax` (dumped only), and the PUREMOUSE_DEV_* settings that open it, without the
# prefix. A row whose settings open a sheet or a shortcut sheet also expects its -sheet capture.
# `all-views` has no pane, so its one dump walks every tab and Mouse segment.
#
# `FIXTURES=a,b` (not a setting, and not passed on) limits a row to those fixtures, for a screen
# that needs a mouse to open. About This Mouse opens from a device row; the Advanced… sheets on
# Buttons and Scrolling need a layout with that section, Pointer's presets a mouse that offers DPI,
# and the shortcut sheet a button to edit, all of which a mouse gives. Every other row runs with
# every fixture.
matrix=(
    "general             shots  PANE=general"
    "buttons             shots  PANE=buttons"
    "scrolling           shots  PANE=scrolling"
    "pointer             shots  PANE=pointer"
    "apps                shots  PANE=apps"
    "about               shots  PANE=about"
    "buttons-all-mice    shots  PANE=buttons MOUSE=all"
    "advanced-general    shots  PANE=general SHEET=advanced"
    "about-mouse         shots  PANE=general SHEET=aboutMouse FIXTURES=one-mouse,two-mice,paused"
    "advanced-buttons    shots  PANE=buttons SHEET=advanced FIXTURES=one-mouse,two-mice,paused"
    "advanced-scrolling  shots  PANE=scrolling SHEET=advanced FIXTURES=one-mouse,two-mice,paused"
    "presets             shots  PANE=pointer SHEET=presets FIXTURES=one-mouse,two-mice,paused"
    "picker              shots  PANE=buttons PICKER=middle"
    "shortcut            shots  PANE=buttons SHORTCUT=middle FIXTURES=one-mouse,two-mice,paused"
    "other-controls      shots  PANE=buttons OTHERS=1"
    "hover-thumb-wheel   shots  PANE=buttons HOVER=thumbWheel"
    "app-page            shots  PANE=apps APP=com.apple.Safari"
    "app-buttons         shots  PANE=apps APP=com.apple.Safari APP_SEGMENT=buttons"
    "app-scrolling       shots  PANE=apps APP=com.apple.Safari APP_SEGMENT=scrolling"
    "app-shortcut        shots  PANE=apps APP=com.apple.Safari SHORTCUT=middle"
    "all-views           ax"
)

# The fixtures, each a status.json (write_status). one-mouse: MX Master 3S on the receiver.
# two-mice: MX Master 3S and MX Master 4. no-mouse: the daemon running, no mouse. paused: one mouse
# and the daemon paused. off: the daemon not running (running false, no devices).
fixtures=(one-mouse two-mice no-mouse paused off)
capture_delay=4

usage() {
    print -u2 -- "usage: scripts/ui-matrix.sh [--binary PATH] [--out DIR] [--only NAME] [--timeout SECONDS]"
    exit 2
}

fail_usage() {
    print -u2 -- "ui-matrix: $*"
    exit 2
}

# physical <path>: the absolute path, with a leading ~ expanded and symlinks in its folder resolved,
# so that a path through a link to the live config is recognised.
physical() {
    local candidate=${1/#\~/$HOME}
    candidate=${candidate:A}
    if [[ -d ${candidate:h} ]]; then
        candidate=$(cd -P -- ${candidate:h} && pwd -P)/${candidate:t}
    fi
    print -r -- "$candidate"
}

binary=$root/.build/debug/PureMouseSettings
out=
only=
limit=120
while (( $# )); do
    case $1 in
        --binary|--out|--only|--timeout)
            (( $# >= 2 )) || fail_usage "$1 needs a value"
            case $1 in
                --binary)  binary=$2 ;;
                --out)     out=$2 ;;
                --only)    only=$2 ;;
                --timeout) limit=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage ;;
        *) print -u2 -- "ui-matrix: unknown argument '$1'"; usage ;;
    esac
done

[[ $limit == <1-> ]] || fail_usage "--timeout takes a whole number of seconds, not '$limit'"

row_only=
fixture_only=
if [[ -n $only ]]; then
    names=()
    for row in "${matrix[@]}"; do names+=("${${(z)row}[1]}"); done
    if (( ${fixtures[(I)$only]} )); then
        fixture_only=$only
    elif (( ${names[(I)$only]} )); then
        row_only=$only
    else
        fail_usage "--only: no matrix row or fixture called '$only'"
    fi
fi

binary=${binary:A}
[[ -f $binary && -x $binary ]] || fail_usage "no executable debug build at $binary (run swift build first)"

# The guard. The real HOME is the one this script was started with, read before anything below
# changes it. An inherited PUREMOUSE_CONFIG, or the --out folder, under the live config folder
# refuses the run.
real_config_dir=$(physical "$HOME/.config/puremouse")
if [[ -n ${PUREMOUSE_CONFIG:-} ]]; then
    given=$(physical "$PUREMOUSE_CONFIG")
    if [[ $given == $real_config_dir || $given == $real_config_dir/* ]]; then
        fail_usage "refusing: PUREMOUSE_CONFIG=$PUREMOUSE_CONFIG resolves under $real_config_dir, the live config. Unset it: the matrix sets its own."
    fi
fi

out=${out:-${TMPDIR:-/tmp}/puremouse-ui-matrix-$(date +%Y%m%d-%H%M%S)}
out=$(physical "$out")
if [[ $out == $real_config_dir || $out == $real_config_dir/* ]]; then
    fail_usage "refusing: --out $out is under $real_config_dir, the live config"
fi
if [[ -d $out && -n "$(ls -A -- "$out")" ]]; then
    fail_usage "--out $out is not empty; give a new folder"
fi
mkdir -p -- "$out" || exit 2

# The sandbox. Set before anything runs: every run inherits these, and PUREMOUSE_DEV_* from the
# caller's shell is cleared so that each run sets only its own.
for name in ${(M)${(k)parameters}:#PUREMOUSE_DEV_*}; do unset "$name"; done
S=$(mktemp -d "${TMPDIR:-/tmp}/puremouse-ui-matrix.XXXXXX") || exit 2
cfg=$S/home/.config/puremouse/config.json
spid=
current=
integer failures=0 runs=0

cleanup() {
    [[ -n $current ]] && kill -9 $current 2>/dev/null
    [[ -n $spid ]] && kill $spid 2>/dev/null
    rm -rf -- "$S"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME=$S/home CFFIXED_USER_HOME=$S/home PUREMOUSE_CONFIG=$cfg \
    PUREMOUSE_DAEMON=$S/daemon PUREMOUSE_COMPANION_DIR=$S/companion
cat > $S/daemon <<'STUB'
#!/bin/zsh
[[ $1 == login-status ]] && print '{"daemon":"enabled","hidden":false,"menu":"enabled","service":"launchd"}'
exit 0
STUB
chmod +x $S/daemon
sleep 3600 & spid=$!

# device <id> <name> <model>: one mouse as status.json reports it.
device() {
    print -rn -- '{"id":"'$1'","name":"'$2'","connection":"receiver","online":true,"battery":{"percent":72,"level":"good","charging":false},"dpi":1600,"dpiSteps":[400,800,1600,3200],"wheelMode":"ratchet","controls":[{"cid":82},{"cid":83},{"cid":86},{"cid":195},{"cid":196},{"cid":416}],"model":"'$3'","kind":"mouse","capabilities":{"dpi":true,"smartShift":true,"smoothScroll":true,"thumbWheel":true,"battery":true,"haptics":true}}'
}
mx3s=$(device 1-1 "MX Master 3S" mb03400000000)
mx4=$(device 1-2 "MX Master 4" mb04200000000)

# write_status <fixture>: the daemon's status.json for a fixture (schema 3, as Companion.swift has it).
write_status() {
    local fixture=$1 running=true paused=false
    local -a devices=()
    case $fixture in
        one-mouse) devices=("$mx3s") ;;
        two-mice)  devices=("$mx3s" "$mx4") ;;
        no-mouse)  ;;
        paused)    paused=true; devices=("$mx3s") ;;
        off)       running=false ;;
    esac
    cat > $S/companion/status.json <<JSON
{"schema":3,"pid":$spid,"startedAt":"2026-11-02T00:00:00Z","version":"ui-matrix","running":$running,"paused":$paused,
 "permissions":{"accessibility":true,"inputMonitoring":true},"logiOptionsRunning":false,
 "config":{"path":"$cfg"},"away":false,"devices":[${(j:,:)devices}]}
JSON
}

# prepare <fixture>: an empty sandbox with the default config and the fixture's status.json.
prepare() {
    rm -rf -- $S/home $S/companion
    mkdir -p -- $S/home/.config/puremouse $S/home/Library/Preferences $S/companion
    print -r -- '{}' > "$cfg"
    write_status "$1"
}

# run_bounded <log> <VAR=value>...: the helper once, with those settings. Sets `outcome` to its exit
# status, or to `hung` after the limit, when the run is killed.
run_bounded() {
    local log=$1; shift
    env "$@" "$binary" > "$log" 2>&1 &
    current=$!
    local waited=0 ticks=$(( limit * 5 ))
    while kill -0 $current 2>/dev/null; do
        if (( waited >= ticks )); then
            kill $current 2>/dev/null
            sleep 1
            kill -9 $current 2>/dev/null
            wait $current 2>/dev/null
            current=
            outcome=hung
            return 0
        fi
        sleep 0.2
        waited=$(( waited + 1 ))
    done
    wait $current 2>/dev/null
    outcome=$?
    current=
}

# record <ok|FAIL> <run> <detail>: one line in summary.txt, and on the terminal.
record() {
    local verdict=$1 run=$2; shift 2
    print -r -- "$(printf '%-4s  %-44s  %s' "$verdict" "$run" "$*")" | tee -a "$out/summary.txt"
    runs=$(( runs + 1 ))
    [[ $verdict == ok ]] || failures=$(( failures + 1 ))
}

# ax_run <row> <fixture> <setting>...: the accessibility dump. Clean only with no finding, exit 0,
# and at least one window dumped.
ax_run() {
    local row=$1 fixture=$2; shift 2
    local log=$out/$row.$fixture.ax.txt run="$row / $fixture / ax"
    local -a envs=(PUREMOUSE_DEV_AX_DUMP=1)
    local setting
    for setting in "$@"; do envs+=(PUREMOUSE_DEV_$setting); done
    prepare "$fixture"
    run_bounded "$log" "${envs[@]}"
    if [[ $outcome == hung ]]; then
        record FAIL "$run" "hung: killed after ${limit}s"
        return 0
    fi
    local windows problems
    windows=$(grep -c '^== ' "$log" 2>/dev/null || true)
    problems=$(grep -c '^PROBLEM ' "$log" 2>/dev/null || true)
    if (( ${problems:-0} > 0 )); then
        record FAIL "$run" "$problems finding(s), see ${log:t}"
    elif [[ $outcome != 0 ]]; then
        record FAIL "$run" "exit $outcome, see ${log:t}"
    elif (( ${windows:-0} == 0 )); then
        record FAIL "$run" "no window dumped, see ${log:t}"
    else
        record ok "$run" "$windows window(s), no findings"
    fi
}

# shot_run <row> <fixture> <light|dark> <setting>...: one capture. Clean only when the window's PNG
# exists, and the sheet's where the settings open one.
shot_run() {
    local row=$1 fixture=$2 appearance=$3; shift 3
    local base=$out/$row.$fixture.$appearance run="$row / $fixture / $appearance"
    local -a envs=(PUREMOUSE_DEV_CAPTURE=$base.png PUREMOUSE_DEV_CAPTURE_OFFSCREEN=1
        PUREMOUSE_DEV_CAPTURE_DELAY=$capture_delay PUREMOUSE_DEV_APPEARANCE=$appearance)
    local setting sheet=0
    for setting in "$@"; do
        envs+=(PUREMOUSE_DEV_$setting)
        if [[ $setting == SHEET=* || $setting == SHORTCUT=* ]]; then sheet=1; fi
    done
    prepare "$fixture"
    run_bounded "$base.log" "${envs[@]}"
    if [[ $outcome == hung ]]; then
        record FAIL "$run" "hung: killed after ${limit}s"
        return 0
    fi
    if [[ $outcome != 0 ]]; then
        record FAIL "$run" "exit $outcome, see ${base:t}.log"
        return 0
    fi
    if grep -q 'capture failed' "$base.log"; then
        record FAIL "$run" "the helper reported capture failed, see ${base:t}.log"
        return 0
    fi
    local -a missing=()
    [[ -s $base.png ]] || missing+=("${base:t}.png")
    if (( sheet )) && [[ ! -s ${base}-sheet.png ]]; then missing+=("${base:t}-sheet.png"); fi
    if (( ${#missing[@]} > 0 )); then
        record FAIL "$run" "missing ${(j:, :)missing}"
    else
        record ok "$run" "$( (( sheet )) && print 'window and sheet' || print window )"
    fi
}

run_matrix() {
    local row name kind fixture appearance word only_fixtures
    local -a f hooks settings
    for row in "${matrix[@]}"; do
        f=(${(z)row})
        name=$f[1] kind=$f[2]
        hooks=("${(@)f[3,-1]}")
        only_fixtures= settings=()
        for word in "${hooks[@]}"; do
            if [[ $word == FIXTURES=* ]]; then only_fixtures=${word#FIXTURES=}; else settings+=("$word"); fi
        done
        [[ -z $row_only || $name == $row_only ]] || continue
        for fixture in "${fixtures[@]}"; do
            [[ -z $fixture_only || $fixture == $fixture_only ]] || continue
            [[ -z $only_fixtures || ,$only_fixtures, == *,$fixture,* ]] || continue
            ax_run "$name" "$fixture" "${settings[@]}"
            if [[ $kind == shots ]]; then
                for appearance in light dark; do
                    shot_run "$name" "$fixture" "$appearance" "${settings[@]}"
                done
            fi
        done
    done
}

print -r -- "ui-matrix $(date '+%Y-%m-%d %H:%M:%S'), helper $binary, limit ${limit}s per run" > "$out/summary.txt"
print -r -- "ui-matrix: writing to $out"
run_matrix
print -r -- "$runs run(s), $failures failed. Summary: $out/summary.txt"
(( runs > 0 )) || fail_usage "nothing matched --only $only"
(( failures == 0 )) || exit 1

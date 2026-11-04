#!/bin/zsh
# Takes the README's Settings screenshots, light and dark, into docs/images (or --out), from a
# debug build of PureMouseSettings. Run it on the spare Mac (AGENTS.md, hard rules): a macOS 27
# host, unlocked, with no other PureMouse Settings window open, since each capture is of the
# window on screen, with its shadow (PUREMOUSE_DEV_CAPTURE_SHADOW=1).
#
# Every run is sandboxed like scripts/ui-matrix.sh: HOME, CFFIXED_USER_HOME, PUREMOUSE_CONFIG,
# PUREMOUSE_DAEMON and PUREMOUSE_COMPANION_DIR point into a temporary folder, the daemon is a stub,
# status.json is one MX Master 3S, and the config is the sample below. No live config, installed
# agent or running daemon is touched. The app pages need Microsoft Excel installed, for its icon
# and name.
#
#   scripts/readme-shots.sh [--binary PATH] [--out DIR] [--only GLOB]
#
#   --binary  the PureMouseSettings debug build (default .build/debug/PureMouseSettings)
#   --out     where the PNGs go (default docs/images)
#   --only    take only the shots whose name matches GLOB, such as 'settings-app*'
#
# Each PNG is scaled to 1000 pixels wide. The menu shots (menu-light.png, menu-dark.png) are not
# taken here: docs/development.md, Screenshots, says how.
set -uo pipefail
root=${0:A:h:h}
binary=$root/.build/debug/PureMouseSettings
out=$root/docs/images
only='*'
while (( $# )); do
    case $1 in
        --binary) binary=$2; shift 2 ;;
        --out)    out=$2; shift 2 ;;
        --only)   only=$2; shift 2 ;;
        *) print -u2 -- "usage: scripts/readme-shots.sh [--binary PATH] [--out DIR] [--only GLOB]"; exit 2 ;;
    esac
done
binary=${binary:A}
[[ -x $binary ]] || { print -u2 -- "readme-shots: no debug build at $binary (run swift build first)"; exit 2 }
mkdir -p -- $out

for name in ${(M)${(k)parameters}:#PUREMOUSE_DEV_*}; do unset "$name"; done
S=$(mktemp -d "${TMPDIR:-/tmp}/puremouse-readme-shots.XXXXXX") || exit 2
mkdir -p $S/companion $S/home/.config/puremouse $S/home/Library/Preferences
sleep 3600 & spid=$!
trap 'kill $spid 2>/dev/null; rm -rf -- $S' EXIT
trap 'exit 130' INT TERM
cfg=$S/home/.config/puremouse/config.json
cat > $S/daemon <<'STUB'
#!/bin/zsh
[[ $1 == login-status ]] && print '{"daemon":"enabled","hidden":false,"menu":"enabled","service":"launchd"}'
exit 0
STUB
chmod +x $S/daemon
cat > $S/companion/status.json <<JSON
{"schema":3,"pid":$spid,"startedAt":"2026-11-04T00:00:00Z","version":"readme","running":true,"paused":false,
 "permissions":{"accessibility":true,"inputMonitoring":true},"logiOptionsRunning":false,
 "config":{"path":"$cfg"},"away":false,"devices":[{"id":"1-1","name":"MX Master 3S","connection":"receiver",
 "online":true,"battery":{"percent":82,"level":"good","charging":false},"dpi":1600,
 "dpiSteps":[400,800,1000,1600,2000,3200,4000],"wheelMode":"ratchet",
 "controls":[{"cid":82},{"cid":83},{"cid":86},{"cid":195},{"cid":196},{"cid":416}],"model":"mb03400000000",
 "kind":"mouse","capabilities":{"dpi":true,"smartShift":true,"smoothScroll":true,"thumbWheel":true,
 "battery":true,"haptics":false}}]}
JSON
# The sample: a double-click and a hold on Forward, Hold and Move on the gesture button, Excel's own
# top button and thumb wheel (named from its action pack), and PureMouse off in Screen Sharing.
cat > $cfg <<'JSON'
{"dpiPresets":[800,1600,3200],
 "buttons":{"gesture":{"click":"missionControl","up":"missionControl","down":"appExpose","left":"spaceLeft","right":"spaceRight"},
  "back":"navigateBack","forward":{"click":"navigateForward","doubleClick":"missionControl","hold":"precisePointer"},
  "top":"cycleDPI"},
 "smoothScroll":{"enabled":true},
 "apps":{
  "com.google.Chrome":{"buttons":{"top":{"keys":"cmd+t"}},"thumbWheel":{"action":"tabs"}},
  "com.microsoft.Excel":{"buttons":{"top":{"keys":"cmd+1"}},"thumbWheel":{"left":{"keys":"opt+left"},"right":{"keys":"opt+right"}}},
  "com.microsoft.teams2":{"thumbWheel":{"action":"volume"}},
  "com.microsoft.Word":{"thumbWheel":{"action":"zoom"}},
  "com.apple.Preview":{"thumbWheel":{"action":"zoom"}},
  "com.apple.Safari":{"buttons":{"top":{"keys":"cmd+shift+t"}},"thumbWheel":{"action":"tabs"}},
  "com.apple.ScreenSharing":{"enabled":false}}}
JSON
export HOME=$S/home CFFIXED_USER_HOME=$S/home PUREMOUSE_CONFIG=$cfg PUREMOUSE_DAEMON=$S/daemon \
    PUREMOUSE_COMPANION_DIR=$S/companion

integer failures=0
# shot <name> <PUREMOUSE_DEV_ setting>...: <name>-light.png and <name>-dark.png, each run killed
# after 30 seconds.
shot() {
    local name=$1; shift
    [[ $name == ${~only} ]] || return 0
    local a png pid n
    for a in light dark; do
        png=$out/$name-$a.png
        rm -f -- $png
        env PUREMOUSE_DEV_APPEARANCE=$a PUREMOUSE_DEV_CAPTURE=$png PUREMOUSE_DEV_CAPTURE_SHADOW=1 \
            PUREMOUSE_DEV_CAPTURE_DELAY=4 "$@" $binary > $S/$name-$a.log 2>&1 &
        pid=$! n=0
        while kill -0 $pid 2>/dev/null && (( n < 30 )); do sleep 1; (( n++ )); done
        kill -0 $pid 2>/dev/null && { print -u2 -- "hung: $name-$a"; kill -9 $pid; }
        wait $pid 2>/dev/null
        if [[ -s $png ]]; then
            sips --resampleWidth 1000 $png > /dev/null && print -- "${png:t}"
        else
            print -u2 -- "no capture: $name-$a"; cat $S/$name-$a.log >&2; (( failures++ ))
        fi
    done
}
shot settings-buttons PUREMOUSE_DEV_PANE=buttons PUREMOUSE_DEV_EXPAND=forward
shot settings-scrolling PUREMOUSE_DEV_PANE=scrolling
shot settings-pointer PUREMOUSE_DEV_PANE=pointer
shot settings-general PUREMOUSE_DEV_PANE=general
shot settings-about-mouse PUREMOUSE_DEV_PANE=general PUREMOUSE_DEV_SHEET=aboutMouse
shot settings-apps PUREMOUSE_DEV_PANE=apps
shot settings-app-actions PUREMOUSE_DEV_PANE=apps PUREMOUSE_DEV_APP=com.microsoft.Excel PUREMOUSE_DEV_PICKER=top
(( failures == 0 ))

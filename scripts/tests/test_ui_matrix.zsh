# Tests for scripts/ui-matrix.sh against a fake PureMouseSettings: no app, no mouse, no daemon, and
# no file outside the test's folder and the matrix's own sandbox (which the script removes).

# fake_helper <dir> <mode>: a stand-in helper in <dir>. Each run appends its sandbox to runs.log,
# copies the status.json it was given to status/, and does what FAKE_MODE asks: `clean` writes every
# capture and a clean dump; `no-capture` writes no capture; `finding` dumps a finding; `hang-ax`
# hangs every dump, recording its pid in hung.pids (as the script's kill must reach it).
fake_helper() {
    local dir=$1
    mkdir -p $dir
    cat > $dir/PureMouseSettings <<'FAKE'
#!/bin/zsh
dir=${0:A:h}
mode=$FAKE_MODE
print -r -- "$HOME|$CFFIXED_USER_HOME|$PUREMOUSE_CONFIG|$PUREMOUSE_DAEMON|$PUREMOUSE_COMPANION_DIR|${PUREMOUSE_DEV_PANE:-}|${PUREMOUSE_DEV_CAPTURE:-}|${PUREMOUSE_DEV_AX_DUMP:-}" >> $dir/runs.log
mkdir -p $dir/status
name=${PUREMOUSE_DEV_CAPTURE:t}
cp $PUREMOUSE_COMPANION_DIR/status.json $dir/status/${name:-ax}.json
if [[ -n ${PUREMOUSE_DEV_AX_DUMP:-} ]]; then
    if [[ $mode == hang-ax ]]; then
        print -r -- $$ >> $dir/hung.pids
        exec sleep 60
    fi
    print -r -- "== pane ${PUREMOUSE_DEV_PANE:-all} / window \"PureMouse Settings\""
    if [[ $mode == finding ]]; then
        print -r -- "PROBLEM pane ${PUREMOUSE_DEV_PANE:-all} / window: unnamed button (30x30)"
        exit 1
    fi
    exit 0
fi
[[ $mode == no-capture ]] && exit 0
print -r -- png > $PUREMOUSE_DEV_CAPTURE
if [[ -n ${PUREMOUSE_DEV_SHEET:-}${PUREMOUSE_DEV_SHORTCUT:-} ]]; then
    print -r -- png > ${PUREMOUSE_DEV_CAPTURE:r}-sheet.png
fi
exit 0
FAKE
    chmod +x $dir/PureMouseSettings
}

# um_run <fake dir> <out dir> [matrix arguments]: the matrix against the fake, setting um_code and
# um_output. FAKE_MODE is exported by the caller.
um_run() {
    local fake=$1 out=$2; shift 2
    um_code=0
    um_output=$(scripts/ui-matrix.sh --binary $fake/PureMouseSettings --out $out "$@" 2>&1) || um_code=$?
}

test_ui_matrix_sandboxes_every_run() {
    fake_helper $tmp/fake
    unset PUREMOUSE_CONFIG
    export FAKE_MODE=clean
    um_run $tmp/fake $tmp/out --only general
    (( um_code == 0 )) || { print -u2 -- $um_output; return 1; }
    local -a lines=("${(@f)$(<$tmp/fake/runs.log)}")
    (( ${#lines[@]} == 15 )) || { print -u2 -- "expected 15 runs, saw ${#lines[@]}"; return 1; }
    local line
    local -a parts
    for line in "${lines[@]}"; do
        parts=("${(@s:|:)line}")
        local home=$parts[1] cffixed=$parts[2] config=$parts[3] daemon=$parts[4] companion=$parts[5]
        [[ -n $home && $home != $HOME && $home != $HOME/* ]] || { print -u2 -- "HOME is not the sandbox: $line"; return 1; }
        [[ $cffixed == $home ]] || { print -u2 -- "CFFIXED_USER_HOME is not HOME: $line"; return 1; }
        [[ $config == $home/.config/puremouse/config.json ]] || { print -u2 -- "PUREMOUSE_CONFIG outside the sandbox: $line"; return 1; }
        [[ $daemon == ${home:h}/daemon && $companion == ${home:h}/companion ]] || { print -u2 -- "daemon or companion dir outside the sandbox: $line"; return 1; }
        [[ ! -e ${home:h} ]] || { print -u2 -- "the sandbox was not removed: ${home:h}"; return 1; }
    done
}

test_ui_matrix_refuses_the_live_config() {
    fake_helper $tmp/fake
    local real=$tmp/real
    mkdir -p $real/.config/puremouse
    ln -s $real/.config $tmp/linked
    export FAKE_MODE=clean
    local config output code
    for config in $real/.config/puremouse/config.json '~/.config/puremouse/config.json' $tmp/linked/puremouse/config.json; do
        code=0
        output=$(HOME=$real PUREMOUSE_CONFIG=$config scripts/ui-matrix.sh --binary $tmp/fake/PureMouseSettings --out $tmp/out-refused 2>&1) || code=$?
        (( code == 2 )) && [[ $output == *"resolves under"* ]] || { print -u2 -- "not refused ($code): $config"; print -u2 -- $output; return 1; }
    done
    code=0
    output=$(HOME=$real scripts/ui-matrix.sh --binary $tmp/fake/PureMouseSettings --out $real/.config/puremouse/captures 2>&1) || code=$?
    (( code == 2 )) && [[ $output == *"live config"* ]] || { print -u2 -- "an --out under the live config was not refused"; return 1; }
    [[ ! -e $tmp/fake/runs.log ]] || { print -u2 -- "a refused run still ran the helper"; return 1; }

    code=0
    output=$(HOME=$real PUREMOUSE_CONFIG=$tmp/elsewhere/config.json scripts/ui-matrix.sh --binary $tmp/fake/PureMouseSettings --out $tmp/out-ok --only general 2>&1) || code=$?
    (( code == 0 )) || { print -u2 -- $output; return 1; }
}

test_ui_matrix_fixtures_describe_each_state() {
    fake_helper $tmp/fake
    unset PUREMOUSE_CONFIG
    export FAKE_MODE=clean
    um_run $tmp/fake $tmp/out --only general
    (( um_code == 0 )) || { print -u2 -- $um_output; return 1; }
    local dir=$tmp/fake/status text
    text=$(<$dir/general.one-mouse.light.png.json)
    [[ $text == *'"running":true'* && $text == *'"paused":false'* && $text == *'"id":"1-1"'* && $text != *'"id":"1-2"'* ]] \
        || { print -u2 -- "one-mouse: $text"; return 1; }
    text=$(<$dir/general.two-mice.light.png.json)
    [[ $text == *'"id":"1-1"'* && $text == *'"id":"1-2"'* ]] || { print -u2 -- "two-mice: $text"; return 1; }
    text=$(<$dir/general.no-mouse.light.png.json)
    [[ $text == *'"running":true'* && $text == *'"devices":[]'* ]] || { print -u2 -- "no-mouse: $text"; return 1; }
    text=$(<$dir/general.paused.light.png.json)
    [[ $text == *'"paused":true'* && $text == *'"id":"1-1"'* ]] || { print -u2 -- "paused: $text"; return 1; }
    text=$(<$dir/general.off.light.png.json)
    [[ $text == *'"running":false'* && $text == *'"devices":[]'* ]] || { print -u2 -- "off: $text"; return 1; }
}

test_ui_matrix_kills_a_hung_run() {
    fake_helper $tmp/fake
    export FAKE_MODE=hang-ax
    um_run $tmp/fake $tmp/out --only general --timeout 1
    (( um_code == 1 )) && [[ $um_output == *"hung: killed after 1s"* ]] \
        || { print -u2 -- "exit $um_code"; print -u2 -- $um_output; return 1; }
    local -a pids=("${(@f)$(<$tmp/fake/hung.pids)}")
    (( ${#pids[@]} == 5 )) || { print -u2 -- "expected 5 hung dumps, saw ${#pids[@]}"; return 1; }
    local pid
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then print -u2 -- "helper $pid is still running"; return 1; fi
    done
}

test_ui_matrix_fails_a_missing_capture() {
    fake_helper $tmp/fake
    export FAKE_MODE=no-capture
    um_run $tmp/fake $tmp/out --only general
    (( um_code == 1 )) && [[ $um_output == *"missing general.one-mouse.light.png"* ]] \
        || { print -u2 -- "exit $um_code"; print -u2 -- $um_output; return 1; }
    grep -q '^FAIL .*missing' $tmp/out/summary.txt
}

test_ui_matrix_fails_a_dump_with_a_finding() {
    fake_helper $tmp/fake
    export FAKE_MODE=finding
    um_run $tmp/fake $tmp/out --only general
    (( um_code == 1 )) && [[ $um_output == *"1 finding(s)"* ]] \
        || { print -u2 -- "exit $um_code"; print -u2 -- $um_output; return 1; }
}

test_ui_matrix_passes_a_clean_run_and_lists_each_run() {
    fake_helper $tmp/fake
    export FAKE_MODE=clean
    um_run $tmp/fake $tmp/out --only general
    (( um_code == 0 )) || { print -u2 -- $um_output; return 1; }
    local oks
    oks=$(grep -c '^ok ' $tmp/out/summary.txt || true)
    (( oks == 15 )) || { print -u2 -- "expected 15 ok lines in summary.txt, saw $oks"; return 1; }
}

test_ui_matrix_limits_a_row_to_its_fixtures() {
    fake_helper $tmp/fake
    export FAKE_MODE=clean
    um_run $tmp/fake $tmp/out --only about-mouse
    (( um_code == 0 )) || { print -u2 -- $um_output; return 1; }
    local oks
    oks=$(grep -c '^ok ' $tmp/out/summary.txt || true)
    (( oks == 9 )) || { print -u2 -- "expected 3 fixtures x 3 runs, saw $oks ok lines"; return 1; }
    if grep -q -e '/ no-mouse /' -e '/ off /' $tmp/out/summary.txt; then
        print -u2 -- "a mouse-only row ran with a fixture that has no mouse"; return 1
    fi
}

test_ui_matrix_rejects_bad_arguments() {
    fake_helper $tmp/fake
    export FAKE_MODE=clean
    um_run $tmp/fake $tmp/out --only nonesuch
    (( um_code == 2 )) || { print -u2 -- "unknown --only: exit $um_code"; return 1; }
    um_run $tmp/fake $tmp/out --timeout soon
    (( um_code == 2 )) || { print -u2 -- "bad --timeout: exit $um_code"; return 1; }
    mkdir -p $tmp/busy && print -r -- x > $tmp/busy/keep
    um_run $tmp/fake $tmp/busy --only general
    (( um_code == 2 )) && [[ $um_output == *"not empty"* ]] || { print -u2 -- "non-empty --out: exit $um_code"; return 1; }
    um_run $tmp/fake $tmp/out --binary $tmp/absent
    (( um_code == 2 )) || { print -u2 -- "missing build: exit $um_code"; return 1; }
}

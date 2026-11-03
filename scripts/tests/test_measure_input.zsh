# Fixture driven tests for measure-input.sh. No real process inspection or mouse activity.

fake_measure_commands() {
    fake_command pgrep 'case ${FAKE_PGREP_MODE:-one} in
    none) exit 1 ;;
    multiple) print "4242\n4243" ;;
    dead) print 987654321 ;;
    *) print -r -- "${FAKE_PID:?}" ;;
esac'
    fake_command top 'print -r -- "$*" >> "${0:A:h}/top.args"
count=0
[[ -f ${0:A:h}/top.count ]] && count=$(<${0:A:h}/top.count)
count=$(( count + 1 )); print -r -- $count > ${0:A:h}/top.count
if [[ ${FAKE_TOP_MODE:-fixtures} == malformed ]]; then print "PID %CPU IDLEW TIME\nnot a process row"; exit 0; fi
fixture=${FAKE_TOP_FIXTURE:-scripts/tests/fixtures/input-top-still.txt}
if [[ -z ${FAKE_TOP_FIXTURE:-} && $count == 3 ]]; then fixture=scripts/tests/fixtures/input-top-moving.txt; fi
sed "s/4242/${FAKE_PID}/g" "$fixture"'
}

# Use the test shell PID so the sampler’s liveness check succeeds without a real daemon.
test_measure_input_reports_still_and_moving_metrics_from_fixtures() {
    fake_measure_commands
    export FAKE_PID=$sysparams[pid]
    local out
    out=$(printf '\n\n' | FAKE_TOP_FIXTURE=scripts/tests/fixtures/input-top-still.txt \
        scripts/measure-input.sh 3 2>&1) || { print -u2 -- "$out"; return 1; }
    [[ $out == *"still: PID "*"duration 3s, 3 samples; mean idle wakeups/s 2.00, mean CPU 40.00%, CPU 3000ms"* ]] || {
        print -u2 -- "$out"; return 1
    }
    [[ $out == *"moving: PID "*"duration 3s, 3 samples; mean idle wakeups/s 10.00, mean CPU 70.00%, CPU 3000ms"* ]] || {
        print -u2 -- "$out"; return 1
    }
    local args=$(< $tmp/fakes/top.args)
    [[ $args == *"-l 1 -s 1"*"-stats pid,cpu,idlew,time"* && $args == *"-l 6 -s 1"* ]] || return 1
}

test_measure_input_rejects_invalid_duration() {
    local out
    if out=$(scripts/measure-input.sh 0 2>&1); then return 1; fi
    [[ $out == *"duration must be a positive whole number"* ]]
}

test_measure_input_names_no_daemon_and_exits_one() {
    fake_measure_commands
    export FAKE_PID=$sysparams[pid]
    local out exit_code
    out=$(FAKE_PGREP_MODE=none scripts/measure-input.sh 3 2>&1); exit_code=$?
    (( exit_code == 1 )) && [[ $out == *"no puremouse daemon found"* ]]
}

test_measure_input_rejects_multiple_daemons() {
    fake_measure_commands
    export FAKE_PID=$sysparams[pid]
    local out
    if out=$(FAKE_PGREP_MODE=multiple scripts/measure-input.sh 3 2>&1); then return 1; fi
    [[ $out == *"multiple puremouse daemons found (2)"* ]]
}

test_measure_input_rejects_malformed_top_samples() {
    fake_measure_commands
    export FAKE_PID=$sysparams[pid]
    local out
    if out=$(FAKE_TOP_MODE=malformed scripts/measure-input.sh 3 2>&1); then return 1; fi
    [[ $out == *"malformed top sample"* ]]
}

test_measure_input_names_process_exit_during_window() {
    fake_measure_commands
    export FAKE_PID=$sysparams[pid]
    local out
    if out=$(printf '\n' | FAKE_PGREP_MODE=dead scripts/measure-input.sh 3 2>&1); then return 1; fi
    [[ $out == *"process 987654321 exited during the still window"* ]]
}

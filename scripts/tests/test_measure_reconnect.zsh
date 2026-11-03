# Fixture driven tests for measure-reconnect.sh's summary. No swift test, daemon or mouse.

test_measure_reconnect_summarises_cycles_within_the_limit() {
    printf 'rig wake 1 500\nrig wake 2 700\nrig wake 3 900\nrig reconnect 1 1200\n' > $tmp/run.txt
    local out
    out=$(scripts/measure-reconnect.sh summarise $tmp/run.txt 2>&1) || { print -u2 -- "$out"; return 1; }
    [[ $out == *"wake"*"3"*"700 ms"*"900 ms"* && $out == *"reconnect"*"1200 ms"* && $out == *"ok: every cycle within 2000 ms"* ]]
}

test_measure_reconnect_fails_above_two_seconds() {
    printf 'rig wake 1 500\nrig wake 2 2001\n' > $tmp/run.txt
    local out code=0
    out=$(scripts/measure-reconnect.sh summarise $tmp/run.txt 2>&1) || code=$?
    (( code == 1 )) && [[ $out == *"FAIL: a cycle took more than 2000 ms"* ]]
}

test_measure_reconnect_rig_failures_are_exit_two() {
    : > $tmp/empty.txt
    local out code=0
    out=$(scripts/measure-reconnect.sh summarise $tmp/empty.txt 2>&1) || code=$?
    (( code == 2 )) && [[ $out == *"no cycles were recorded"* ]] || return 1
    out=$(scripts/measure-reconnect.sh fake --cycles 0 2>&1) || code=$?
    (( code == 2 )) && [[ $out == *"positive whole number"* ]]
}

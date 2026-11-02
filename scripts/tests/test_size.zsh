# check-size.sh against the budget.

test_size_over_budget_fails_with_both_sizes() {
    local app=$(stand_in_app $tmp 1.2.3) output
    if output=$(INSTALLED_MAX_BYTES=1000 scripts/check-size.sh $app 2>&1); then return 1; fi
    [[ $output == *"installed size "<->" bytes"*"allowed 1000 bytes"* ]] || { print -u2 -- $output; return 1; }
}

test_size_within_budget_passes() {
    local app=$(stand_in_app $tmp 1.2.3)
    INSTALLED_MAX_BYTES=100000000 scripts/check-size.sh $app >/dev/null
}

test_size_counts_every_file() {
    local app=$(stand_in_app $tmp 1.2.3) before after
    before=$(INSTALLED_MAX_BYTES=100000000 scripts/check-size.sh $app)
    head -c 12345 /dev/zero > $app/Contents/Resources/padding
    after=$(INSTALLED_MAX_BYTES=100000000 scripts/check-size.sh $app)
    local b=${${before#*installed size }%% *} a=${${after#*installed size }%% *}
    (( a - b == 12345 )) || { print -u2 -- "$b -> $a"; return 1; }
}

test_size_budget_holds_for_the_built_bundle() {
    local app
    app=$(real_app)
    scripts/check-size.sh $app
}

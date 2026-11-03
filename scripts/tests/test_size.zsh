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

test_dmg_over_budget_fails_with_both_sizes() {
    local dmg=$tmp/PureMouse.dmg output
    head -c 5000 /dev/zero > $dmg
    if output=$(DMG_MAX_BYTES=4999 scripts/check-size.sh $dmg 2>&1); then return 1; fi
    [[ $output == *"dmg size 5000 bytes"*"allowed 4999 bytes"*"DMG_MAX_BYTES"* ]] || { print -u2 -- $output; return 1; }
}

test_dmg_within_budget_passes_whatever_the_installed_budget() {
    local dmg=$tmp/PureMouse.dmg
    head -c 5000 /dev/zero > $dmg
    DMG_MAX_BYTES=5000 INSTALLED_MAX_BYTES=1 scripts/check-size.sh $dmg >/dev/null
}

# The budgets are the measurements plus 15%, rounded up to 0.1 MB, plus the extra allowance
# size-budget.env explains, and the README quotes the measurements rounded to 0.1 MB: none of the
# three is maintained by hand.
test_budgets_and_the_readme_follow_the_measured_sizes() {
    local INSTALLED_MEASURED_BYTES DMG_MEASURED_BYTES INSTALLED_MAX_BYTES DMG_MAX_BYTES INSTALLED_EXTRA_BYTES DMG_EXTRA_BYTES
    source $root/scripts/size-budget.env
    local problems=() name measured tenths
    for name in INSTALLED DMG; do
        measured=${(P)${:-${name}_MEASURED_BYTES}}
        (( (measured * 115 + 9999999) / 10000000 * 100000 + ${(P)${:-${name}_EXTRA_BYTES}} == ${(P)${:-${name}_MAX_BYTES}} )) ||
            problems+="${name}_MAX_BYTES is not ${name}_MEASURED_BYTES plus 15%, rounded up to 0.1 MB, plus ${name}_EXTRA_BYTES"
    done
    local -A mb
    for name in INSTALLED DMG; do
        measured=${(P)${:-${name}_MEASURED_BYTES}}
        tenths=$(( (measured + 50000) / 100000 ))
        mb[$name]="$(( tenths / 10 )).$(( tenths % 10 ))"
    done
    grep -qF "| Download | ${mb[DMG]} MB dmg, ${mb[INSTALLED]} MB installed;" $root/README.md ||
        problems+="the README's Download row is not '${mb[DMG]} MB dmg, ${mb[INSTALLED]} MB installed'"
    (( ! $#problems )) || { print -u2 -- ${(F)problems}; return 1; }
}

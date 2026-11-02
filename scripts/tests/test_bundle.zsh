# Bundle layout, Info.plists, signing and verify-bundle.sh.

test_verify_passes_on_the_built_bundle() {
    local app=$(real_app)
    scripts/verify-bundle.sh $app
}

test_verify_names_a_nested_app_without_hardened_runtime() {
    local app=$(real_app) output
    # `--options none` is refused ("invalid argument") by codesign on macOS 27; 0 clears the flags.
    codesign --force --sign - --options 0 "$(menu_of $app)" 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verify-bundle.sh passed a menu app without the hardened runtime"
        return 1
    fi
    [[ $output == *'PureMouse Menu.app: no hardened runtime'* ]]
}

test_stand_in_bundle_signs_with_runtime_and_verifies() {
    local app=$(stand_in_app $tmp 1.2.3)
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    local bundle details
    for bundle in $app "$(menu_of $app)"; do
        details=$(codesign -dv $bundle 2>&1)
        expect "$bundle flags (adhoc,runtime)" eval '[[ $details == *"flags=0x10002(adhoc,runtime)"* ]]'
    done
    scripts/verify-bundle.sh $app
}

test_verify_names_a_component_with_the_wrong_identifier() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    codesign --force --sign - --options runtime --identifier com.example.other "$(menu_of $app)" 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Menu.app: signed as 'com.example.other'"* ]]
}

test_verify_fails_an_unsigned_bundle() {
    local app=$(stand_in_app $tmp 1.2.3)
    ! scripts/verify-bundle.sh $app 2>/dev/null
}

test_info_plists_lint_and_differ_only_in_role_keys() {
    local app=$(stand_in_app $tmp 1.2.3)
    local daemon=$app/Contents/Info.plist menu="$(menu_of $app)/Contents/Info.plist"
    plutil -lint -s $daemon "$menu"
    local differing=$(diff $daemon "$menu" | sed -n 's/^[<>] *<key>\([^<]*\)<.*/\1/p' | sort -u)
    local expected=$'CFBundleDisplayName\nCFBundleExecutable\nCFBundleIdentifier\nLSBackgroundOnly'
    [[ $differing == $expected ]] || { print -u2 -- "differing keys: ${(f)differing}"; return 1; }
    for key in CFBundleVersion NSHumanReadableCopyright LSApplicationCategoryType; do
        expect "$key in both" eval '/usr/libexec/PlistBuddy -c "Print :$key" $daemon >/dev/null &&
            /usr/libexec/PlistBuddy -c "Print :$key" "$menu" >/dev/null'
    done
}

test_pinned_version_reaches_both_plists() {
    local version=$(PUREMOUSE_VERSION=v1.2.3 resolve_version)
    [[ $version == 1.2.3 ]] || { print -u2 -- "resolved $version"; return 1; }
    local app=$(stand_in_app $tmp $version)
    for plist in $app/Contents/Info.plist "$(menu_of $app)/Contents/Info.plist"; do
        expect "1.2.3 in $plist" \
            eval '[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist") == 1.2.3 ]]'
    done
}

test_release_verify_rejects_a_described_version() {
    local app=$(stand_in_app $tmp 0.3.0-5-gabc1234) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    scripts/verify-bundle.sh $app >/dev/null
    if output=$(PUREMOUSE_TEAM_ID= scripts/verify-bundle.sh $app --release 2>&1); then return 1; fi
    [[ $output == *"version '0.3.0-5-gabc1234' is not a release version"* ]]
}

test_release_verify_without_team_runs_base_checks_only() {
    local app=$(stand_in_app $tmp 1.2.3-rc.1)
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    PUREMOUSE_TEAM_ID= scripts/verify-bundle.sh $app --release
}

test_release_verify_with_team_rejects_ad_hoc() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(PUREMOUSE_TEAM_ID=ABCDE12345 scripts/verify-bundle.sh $app --release 2>&1); then return 1; fi
    [[ $output == *'PureMouse Menu.app: not signed by a Developer ID Application identity'* ]]
    [[ $output == *'FAIL PureMouse.app: not signed by a Developer ID Application identity'* ]]
}

test_release_signature_accepts_developer_id_of_the_team() {
    check_release_signature "$(<$fixtures/codesign-developer-id.txt)" ABCDE12345 PureMouse.app
}

test_release_signature_rejects_another_team() {
    local output
    if output=$(check_release_signature "$(<$fixtures/codesign-developer-id.txt)" ZZZZZ99999 PureMouse.app 2>&1); then
        return 1
    fi
    [[ $output == "PureMouse.app: team is ABCDE12345, not ZZZZZ99999" ]]
}

test_release_signature_rejects_self_signed() {
    ! check_release_signature "$(<$fixtures/codesign-self-signed.txt)" ABCDE12345 PureMouse.app 2>/dev/null
}

test_release_versions() {
    for good in 0.4.0 1.2.3 10.20.30 0.4.0-rc.1; do
        expect "$good accepted" release_version_ok $good
    done
    for bad in 0.3.0-5-gabc1234 0.3.0-dirty v1.2.3 1.2 dev 0.0.0-ci.abc1234 1.2.3-rc; do
        expect "$bad rejected" eval '! release_version_ok $bad'
    done
}

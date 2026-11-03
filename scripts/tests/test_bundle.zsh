# Bundle layout, Info.plists, signing and verify-bundle.sh.

# Mutate one real Mach-O slice, then sign normally so only the build-version check can fail.
# These fixtures need only plists and executables, independent of icon assembly and hard links.
build_version_app() {
    local app=$tmp/PureMouse.app component bundle executable role
    for component in $components; do
        bundle=$(component_path $app $component)
        executable=$(component_executable $component)
        case $executable in
            puremouse) role=daemon ;;
            PureMouseMenu) role=menu ;;
            PureMouseSettings)
                role=settings
                mkdir -p $bundle/Contents/Resources
                touch $bundle/Contents/Resources/ActionPacks.json
                ;;
        esac
        mkdir -p $bundle/Contents/MacOS
        xcrun vtool -set-build-version macos $minimum $minimum_sdk.0 -replace \
            -output $bundle/Contents/MacOS/$executable /usr/bin/true
        write_info_plist $bundle/Contents/Info.plist $(component_id $component) $executable 1.2.3 42 $role
    done
    print -r -- $app
}

verify_rejects_build_version() {
    local target=$1 arch=$2 minos=$3 sdk=$4 expected=$5
    local app output
    app=$(build_version_app)
    local executable=$app/$target
    xcrun vtool -arch $arch -set-build-version macos $minos $sdk -replace \
        -output $tmp/changed $executable
    cp $tmp/changed $executable
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    expect "the signature still verifies" codesign --verify --strict $app
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verifier accepted $executable ($arch): minos $minos SDK $sdk"
        return 1
    fi
    [[ $output == *"$executable ($arch): $expected"* ]] || { print -u2 -- $output; return 1; }
    [[ $(print -r -- $output | grep -c '^FAIL ') == 1 ]]
}

test_sdk_verifier_rejects_an_old_sdk_in_the_intel_settings_slice() {
    verify_rejects_build_version 'Contents/Helpers/PureMouse Settings.app/Contents/MacOS/PureMouseSettings' \
        x86_64 14.0 14.0 "SDK is '14.0', needs macOS 26 or later"
}

test_sdk_verifier_rejects_a_different_minimum_in_the_intel_menu_slice() {
    verify_rejects_build_version 'Contents/Library/LoginItems/PureMouse Menu.app/Contents/MacOS/PureMouseMenu' \
        x86_64 15.0 26.0 "minos is '15.0', not 14.0"
}

test_sdk_verifier_rejects_a_lower_minimum_in_the_daemon() {
    verify_rejects_build_version Contents/MacOS/puremouse x86_64 13.0 26.0 "minos is '13.0', not 14.0"
}

test_sdk_verifier_accepts_a_newer_sdk() {
    local app
    app=$(build_version_app)
    xcrun vtool -set-build-version macos 14.0 27.2 -replace \
        -output $tmp/changed $app/Contents/MacOS/puremouse
    cp $tmp/changed $app/Contents/MacOS/puremouse
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    scripts/verify-bundle.sh $app
}

test_verify_passes_on_the_built_bundle() {
    local app
    app=$(real_app)
    scripts/verify-bundle.sh $app
}

test_verify_names_a_nested_app_without_hardened_runtime() {
    local app output
    app=$(real_app)
    # `--options none` is refused ("invalid argument") by codesign on macOS 27; 0 clears the flags.
    codesign --force --sign - --options 0 "$(menu_of $app)" 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verify-bundle.sh passed a menu app without the hardened runtime"
        return 1
    fi
    [[ $output == *'PureMouse Menu.app ('*'): no hardened runtime'* ]]
}

test_stand_in_bundle_signs_with_runtime_and_verifies() {
    local app=$(stand_in_app $tmp 1.2.3)
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    local bundle details
    for bundle in $app "$(menu_of $app)" "$(settings_of $app)"; do
        details=$(codesign -dv $bundle 2>&1)
        expect "$bundle flags (adhoc,runtime)" eval '[[ $details == *"flags=0x10002(adhoc,runtime)"* ]]'
    done
    scripts/verify-bundle.sh $app
    local signed=() component
    for component in $components; do
        signed+=$(codesign -dv "$(component_path $app $component)" 2>&1 | sed -n 's/^Identifier=//p')
    done
    [[ ${(j: :)signed} == "$menu_label $settings_label $label" ]] || { print -u2 -- "signed as: $signed"; return 1; }
}

test_verify_names_a_component_with_the_wrong_identifier() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    codesign --force --sign - --options runtime --identifier com.example.other "$(menu_of $app)" 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Menu.app ("*"): signed as 'com.example.other'"* ]]
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
    local expected=$'CFBundleDisplayName\nCFBundleExecutable\nCFBundleIdentifier\nLSBackgroundOnly\nLSEnvironment'
    [[ $differing == $expected ]] || { print -u2 -- "differing keys: ${(f)differing}"; return 1; }
    for key in CFBundleVersion NSHumanReadableCopyright LSApplicationCategoryType; do
        expect "$key in both" eval 'plist_value $daemon $key >/dev/null && plist_value "$menu" $key >/dev/null'
    done
}

test_menu_info_plist_sets_the_allocator_variable_for_finder_launches() {
    local app=$(stand_in_app $tmp 1.2.3)
    local menu="$(menu_of $app)/Contents/Info.plist"
    [[ $(/usr/libexec/PlistBuddy -c "Print :LSEnvironment:MallocSpaceEfficient" "$menu") == 1 ]] || return 1
    ! /usr/libexec/PlistBuddy -c "Print :LSEnvironment" $app/Contents/Info.plist >/dev/null 2>&1
}

test_settings_plist_is_a_regular_app_with_its_own_identifier() {
    local app=$(stand_in_app $tmp 1.2.3)
    local menu="$(menu_of $app)/Contents/Info.plist" settings="$(settings_of $app)/Contents/Info.plist"
    plutil -lint -s "$settings"
    local differing=$(diff "$menu" "$settings" | sed -n 's/^[<>] *<key>\([^<]*\)<.*/\1/p' | sort -u)
    local expected=$'CFBundleDisplayName\nCFBundleExecutable\nCFBundleIdentifier\nLSUIElement'
    [[ $differing == $expected ]] || { print -u2 -- "differing keys: ${(f)differing}"; return 1; }
    # Its own allocator setting, for the opens that do not pass on the menu app's environment.
    [[ $(/usr/libexec/PlistBuddy -c "Print :LSEnvironment:MallocSpaceEfficient" "$settings") == 1 ]] || return 1
    [[ $(plist_value "$settings" CFBundleIdentifier) == io.github.mblauberg.puremouse.settings ]]
    [[ $(plist_value "$settings" LSUIElement) == false ]]
    [[ $(plist_value "$settings" CFBundleDisplayName) == "PureMouse Settings" ]]
    [[ $(settings_of $app) == "$app/Contents/Helpers/PureMouse Settings.app" ]]
    [[ -x "$(settings_of $app)/Contents/MacOS/$(plist_value "$settings" CFBundleExecutable)" ]]
    # The Dock draws its icon from Assets.car in every icon style, as it does PureMouse.app's.
    [[ $app/Contents/Resources/Assets.car -ef "$(settings_of $app)/Contents/Resources/Assets.car" ]]
    # The About pane draws these; the menu bar app shows no About pane.
    [[ -f "$(settings_of $app)/Contents/Resources/AppIcon-dark.png" ]]
    [[ ! -e "$(menu_of $app)/Contents/Resources/AppIcon-dark.png" ]]
}

# One icon catalogue on disk, three names for it: the menu bar app's own (macOS 26+ draws its dark,
# clear and tinted icons from it) and the helper's are hard links to PureMouse.app's, which ditto,
# the dmg and codesign all keep. A copy would grow the dmg by 1.8 MB each; a symlink out of the
# nested bundle fails codesign.
test_nested_apps_hard_link_the_icon_catalogue() {
    local app=$(stand_in_app $tmp 1.2.3) nested
    for nested in "$(menu_of $app)" "$(settings_of $app)"; do
        [[ $app/Contents/Resources/Assets.car -ef $nested/Contents/Resources/Assets.car ]] ||
            { print -u2 -- "$nested has its own Assets.car"; return 1; }
        [[ ! -L $nested/Contents/Resources/Assets.car ]] || { print -u2 -- "$nested: symlink"; return 1; }
    done
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    scripts/verify-bundle.sh $app
    local copy=$tmp/copy/PureMouse.app
    mkdir -p $tmp/copy && ditto $app $copy
    [[ $copy/Contents/Resources/Assets.car -ef "$(menu_of $copy)/Contents/Resources/Assets.car" ]]
    scripts/verify-bundle.sh $copy
}

test_pinned_version_reaches_both_plists() {
    local version=$(PUREMOUSE_VERSION=v1.2.3 resolve_version)
    [[ $version == 1.2.3 ]] || { print -u2 -- "resolved $version"; return 1; }
    local app=$(stand_in_app $tmp $version)
    for plist in $app/Contents/Info.plist "$(menu_of $app)/Contents/Info.plist" "$(settings_of $app)/Contents/Info.plist"; do
        expect "1.2.3 in $plist" \
            eval '[[ $(plist_value "$plist" CFBundleShortVersionString) == 1.2.3 ]]'
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
    [[ $output == *'PureMouse Menu.app ('*'): not signed by a Developer ID Application identity'* ]]
    [[ $output == *'FAIL PureMouse.app ('*'): not signed by a Developer ID Application identity'* ]]
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

test_verify_names_a_menu_app_with_another_version() {
    local app=$(stand_in_app $tmp 1.2.3) output
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$(menu_of $app)/Contents/Info.plist"
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Menu.app: CFBundleShortVersionString is '9.9.9', not '1.2.3' as in the app"* ]]
}

test_verify_names_a_plist_with_the_wrong_identifier() {
    local app=$(stand_in_app $tmp 1.2.3) output
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.other" "$(menu_of $app)/Contents/Info.plist"
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Menu.app: CFBundleIdentifier is 'com.example.other'"* ]]
}

test_verify_names_a_plist_that_does_not_parse() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    print 'not a plist' > "$(menu_of $app)/Contents/Info.plist"
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Menu.app: Info.plist does not parse"* ]]
}

test_verify_names_a_bundle_changed_after_signing() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    print extra >> "$(settings_of $app)/Contents/Resources/AppIcon.png"
    if output=$(scripts/verify-bundle.sh $app 2>&1); then return 1; fi
    [[ $output == *"PureMouse Settings.app: signature does not verify"* ]]
}

test_release_signature_needs_a_developer_id_authority() {
    local output
    if output=$(check_release_signature $'Authority=Some CA\nTeamIdentifier=ABCDE12345' ABCDE12345 PureMouse.app 2>&1); then
        return 1
    fi
    [[ $output == "PureMouse.app: not signed by a Developer ID Application identity" ]]
}

test_developer_id_requirement_compiles_and_rejects_ad_hoc() {
    local app=$(stand_in_app $tmp 1.2.3)
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    local requirement=$(developer_id_requirement ABCDE12345)
    csreq -r="$requirement" -t >/dev/null
    ! codesign --verify --strict -R="$requirement" $app 2>/dev/null
}

test_release_verify_rejects_a_malformed_team() {
    local app=$(stand_in_app $tmp 1.2.3) output
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(PUREMOUSE_TEAM_ID='AB"C' scripts/verify-bundle.sh $app --release 2>&1); then return 1; fi
    [[ $output == *"is not a 10-character team ID"* ]]
}

# A universal bundle whose Intel slice lacks the hardened runtime but whose signature is otherwise
# valid: both signings seal the same Info.plist and resources, so splicing the slices keeps it valid.
test_verify_names_a_slice_without_hardened_runtime() {
    local app=$(stand_in_app $tmp 1.2.3) output
    local menu=$(menu_of $app)
    local executable=$menu/Contents/MacOS/PureMouseMenu
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    codesign --force --sign - --options 0 --identifier $menu_label $menu 2>/dev/null
    lipo $executable -thin x86_64 -output $tmp/x86_64
    codesign --force --sign - --options runtime --identifier $menu_label $menu 2>/dev/null
    lipo $executable -replace x86_64 $tmp/x86_64 -output $tmp/mixed
    cp $tmp/mixed $executable
    codesign --force --sign - --options runtime --identifier $label $app 2>/dev/null
    expect "the spliced bundle still verifies" codesign --verify --strict $app
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verify-bundle.sh passed an Intel slice without the hardened runtime"
        return 1
    fi
    [[ $output == *'PureMouse Menu.app (x86_64): no hardened runtime (flags=0x2(adhoc))'* ]] ||
        { print -u2 -- $output; return 1; }
    [[ $output != *'(arm64'* ]] || { print -u2 -- "an Apple silicon slice failed too: $output"; return 1; }
}

test_verify_takes_one_app() {
    local app=$(stand_in_app $tmp 1.2.3) output
    if output=$(scripts/verify-bundle.sh $app $app 2>&1); then return 1; fi
    [[ $output == *'one app at a time'* ]]
}

test_verify_checks_action_packs_in_settings_helper() {
    local app output
    app=$(build_version_app)
    local settings_res="$(component_path $app "$(settings_component)")/Contents/Resources"
    rm -f $settings_res/ActionPacks.json
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verifier accepted bundle missing ActionPacks.json"
        return 1
    fi
    [[ $output == *"missing action packs catalogue in Settings helper"* ]]
}

test_verify_rejects_action_packs_in_menu_or_daemon() {
    local app output
    app=$(build_version_app)
    mkdir -p $app/Contents/Resources
    touch $app/Contents/Resources/ActionPacks.json
    scripts/sign-bundle.sh $app --identity - 2>/dev/null
    if output=$(scripts/verify-bundle.sh $app 2>&1); then
        print -u2 -- "verifier accepted stray ActionPacks.json in daemon resources"
        return 1
    fi
    [[ $output == *"action packs catalogue belongs to the Settings helper alone"* ]]
}

# install.sh and uninstall.sh against a temporary install directory, a stubbed build and fake
# launchctl, pkill and pgrep. Never the real /Applications or the real agents.

# setup_install [stub mode]: sets up $repo, the fake launchd and an installed old app; prints nothing.
setup_install() {
    repo=$(script_repo)
    stub_build_app $repo ${1:-}
    fake_launchd
    export PUREMOUSE_INSTALL_DIR=$tmp/Applications HOME=$tmp/home
    mkdir -p $tmp/Applications/PureMouse.app $tmp/home
    touch $tmp/Applications/PureMouse.app/OLD
}

test_install_stops_the_agents_then_replaces_the_app() {
    local repo
    setup_install
    $repo/scripts/install.sh >/dev/null
    expect "the new app is installed" test -e $tmp/Applications/PureMouse.app/Contents/Resources/NEW
    expect "the old app is gone" test ! -e $tmp/Applications/PureMouse.app/OLD
    expect "no staged or previous copy is left" test -z "$(print -l $tmp/Applications/.PureMouse.app.*(N))"
    local log=$(<$tmp/fakes/launchctl.log)
    [[ $log == *"bootout gui/$UID/$menu_label"*"bootout gui/$UID/$label"* ]] || { print -u2 -- $log; return 1; }
    # Settings has no agent; it is quit (and saves its edits) before its bundle is replaced.
    grep -qx "pkill -x -u $UID PureMouseSettings" $tmp/fakes/launchctl.log || { print -u2 -- $log; return 1; }
}

test_install_keeps_the_installed_app_when_the_staged_one_does_not_verify() {
    local repo output
    setup_install wrong-identifier
    # codesign alone accepts this bundle; only verify-bundle.sh sees the wrong identifier.
    if output=$($repo/scripts/install.sh 2>&1); then
        print -u2 -- "install.sh installed a bundle that verify-bundle.sh rejects"
        return 1
    fi
    [[ $output == *"signed as 'com.example.other'"* ]] || { print -u2 -- $output; return 1; }
    expect "the installed app is untouched" test -e $tmp/Applications/PureMouse.app/OLD
    expect "the new app was not installed" test ! -e $tmp/Applications/PureMouse.app/Contents
    expect "the staged copy is removed" test ! -e $tmp/Applications/.PureMouse.app.new
}

test_uninstall_stops_the_agents_and_removes_the_app_and_agents_but_not_the_config() {
    local repo
    setup_install
    mkdir -p $tmp/home/Library/LaunchAgents $tmp/home/.config/puremouse
    touch $tmp/home/Library/LaunchAgents/$label.plist $tmp/home/Library/LaunchAgents/$menu_label.plist
    touch $tmp/home/.config/puremouse/config.json
    expect "both agent plists exist before" test -e $tmp/home/Library/LaunchAgents/$menu_label.plist -a -e $tmp/home/Library/LaunchAgents/$label.plist
    $repo/scripts/uninstall.sh >/dev/null
    expect "the app is removed" test ! -e $tmp/Applications/PureMouse.app
    expect "both agents are removed" test -z "$(print -l $tmp/home/Library/LaunchAgents/*(N))"
    expect "the config is kept" test -e $tmp/home/.config/puremouse/config.json
    local log=$(<$tmp/fakes/launchctl.log)
    [[ $log == *"bootout gui/$UID/$menu_label"*"bootout gui/$UID/$label"* ]] || { print -u2 -- $log; return 1; }
}

test_stopping_ignores_another_users_menu_bar_app() {
    local repo
    setup_install
    FAKE_OTHER_USERS_MENU=1 $repo/scripts/install.sh >/dev/null
    expect "the new app is installed" test -e $tmp/Applications/PureMouse.app/Contents/Resources/NEW
    grep -qx "pkill -x -u $UID PureMouseMenu" $tmp/fakes/launchctl.log || { print -u2 -- "$(<$tmp/fakes/launchctl.log)"; return 1; }
}

test_stopping_names_the_agent_that_will_not_stop() {
    local repo output
    setup_install
    if output=$(FAKE_LOADED=$label PUREMOUSE_STOP_TENTHS=2 $repo/scripts/uninstall.sh 2>&1); then return 1; fi
    [[ $output == "PureMouse is still running, so nothing was removed; try: launchctl bootout gui/$UID/$label" ]] ||
        { print -u2 -- $output; return 1; }
    expect "the app was not removed" test -e $tmp/Applications/PureMouse.app/OLD
}

test_stopping_names_the_process_that_will_not_stop() {
    local repo output
    setup_install
    if output=$(FAKE_MENU_RUNNING=1 PUREMOUSE_STOP_TENTHS=2 $repo/scripts/install.sh 2>&1); then return 1; fi
    [[ $output == "PureMouse is still running, so it was not replaced; try: pkill -x -u $UID PureMouseMenu" ]] ||
        { print -u2 -- $output; return 1; }
    expect "the installed app is untouched" test -e $tmp/Applications/PureMouse.app/OLD
}

# The process names and agents come from `components`: a nested bundle added there is stopped too.
test_stopping_covers_every_nested_component() {
    fake_launchd
    components=("$label.helper:Contents/Library/LoginItems/Helper.app:PureMouseHelper" $components)
    stop_agents "x"
    local log=$(<$tmp/fakes/launchctl.log)
    [[ $log == *"bootout gui/$UID/$label.helper"* ]] || { print -u2 -- $log; return 1; }
    [[ $log == *"pkill -x -u $UID PureMouseHelper"* && $log == *"pkill -x -u $UID PureMouseMenu"* ]] || { print -u2 -- $log; return 1; }
    [[ $log != *"pkill -x -u $UID puremouse"* ]] || { print -u2 -- "the daemon's process was killed: $log"; return 1; }
}

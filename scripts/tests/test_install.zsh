# install.sh and uninstall.sh against a temporary install directory, a stubbed build and fake
# launchctl, pkill and pgrep. Never the real /Applications or the real agents.

# setup_install [stub mode]: sets up $repo, the fake launchd and an installed old app; prints nothing.
setup_install() {
    repo=$(script_repo)
    stub_build_app $repo ${1:-}
    fake_launchd $tmp/fakes
    export PATH=$tmp/fakes:$PATH PUREMOUSE_INSTALL_DIR=$tmp/Applications HOME=$tmp/home
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

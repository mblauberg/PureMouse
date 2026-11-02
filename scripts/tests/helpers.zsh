# Helpers for scripts/tests: sourced by run.sh.

fixtures=${0:A:h}/fixtures

# expect <description> <command...>: runs the command and fails the test unless it succeeds.
expect() {
    local description=$1; shift
    "$@" || { print -u2 -- "expected: $description"; return 1; }
}

# skip <reason>: ends the test as skipped. The reason goes to stderr so that it survives a skip
# inside a command substitution (`app=$(real_app)`).
skip() {
    print -u2 -- "$1"
    exit 77
}

# stand_in_app <dir> <version>: an unsigned PureMouse.app laid out by assemble_bundle, with
# /usr/bin/true as both executables. Prints its path.
stand_in_app() {
    local dir=$1 version=$2
    mkdir -p $dir/bin
    cp /usr/bin/true $dir/bin/puremouse
    cp /usr/bin/true $dir/bin/PureMouseMenu
    assemble_bundle $dir/bin $dir/PureMouse.app $version 42 >/dev/null
    print -r -- $dir/PureMouse.app
}

# real_app: a copy of the built bundle in $tmp, or skip. Assign it apart from `local`
# (`local app; app=$(real_app)`): `local app=$(real_app)` takes local's status and loses the skip.
real_app() {
    local source=${PUREMOUSE_TEST_APP:-$root/.build/app/PureMouse.app}
    [[ -d $source ]] || skip "no built bundle at $source (run scripts/build-app.sh)"
    ditto $source $tmp/real/PureMouse.app
    print -r -- $tmp/real/PureMouse.app
}

# menu_of <app>: the nested menu bar app.
menu_of() {
    component_path $1 "$(menu_component)"
}

# script_repo: a git repository in $tmp/repo holding a copy of the scripts (not the tests), so a
# test can swap one for a stub, run another from a tagged commit and leave this checkout alone.
# The assets and config.example.json are linked in for assemble_bundle. Prints its path.
script_repo() {
    local repo=$tmp/repo
    mkdir -p $repo/scripts
    cp $root/scripts/*.(sh|zsh|env) $repo/scripts/
    ln -s $root/assets $repo/assets
    ln -s $root/config.example.json $repo/config.example.json
    print -r -- $repo
}

# stub_build_app <repo> [wrong-identifier]: replaces the repo's build-app.sh with one that lays out
# a stand-in bundle around /usr/bin/true, signed ad hoc by the repo's sign-bundle.sh and carrying a
# NEW marker file. With wrong-identifier the menu app is signed as another identifier, which
# codesign accepts and verify-bundle.sh does not. The bundle version is a trailing `--version V`
# (release.sh's), else 9.9.9.
stub_build_app() {
    local repo=$1 mode=${2:-}
    cat > $repo/scripts/build-app.sh <<STUB
#!/bin/zsh
set -euo pipefail
source "\${0:A:h}/lib.zsh"
cd \$root
version=9.9.9
(( \$# >= 2 )) && [[ \${@[-2]} == --version ]] && version=\${@[-1]}
mkdir -p .build/stub
cp /usr/bin/true .build/stub/puremouse
cp /usr/bin/true .build/stub/PureMouseMenu
assemble_bundle .build/stub .build/app/PureMouse.app \$version 1
touch .build/app/PureMouse.app/Contents/Resources/NEW
scripts/sign-bundle.sh .build/app/PureMouse.app --identity - 2>/dev/null
if [[ '$mode' == wrong-identifier ]]; then
    menu=\$(component_path .build/app/PureMouse.app "\$(menu_component)")
    codesign --force --sign - --options runtime --identifier com.example.other \$menu 2>/dev/null
    codesign --force --sign - --options runtime --identifier \$label .build/app/PureMouse.app 2>/dev/null
fi
STUB
    chmod +x $repo/scripts/build-app.sh
}

# fake_launchd <dir>: launchctl, pkill and pgrep stand-ins on <dir>, so a test can run install.sh and
# uninstall.sh without touching the real agents. launchctl logs its arguments to <dir>/launchctl.log
# and reports every service as not loaded.
fake_launchd() {
    local dir=$1
    mkdir -p $dir
    print -r -- '#!/bin/zsh
print -r -- "$@" >> "${0:A:h}/launchctl.log"
[[ $1 == print ]] && exit 1
exit 0' > $dir/launchctl
    print -r -- '#!/bin/zsh
print -r -- "pkill $@" >> "${0:A:h}/launchctl.log"
exit 1' > $dir/pkill
    print -r -- '#!/bin/zsh
exit 1' > $dir/pgrep
    chmod +x $dir/{launchctl,pkill,pgrep}
}

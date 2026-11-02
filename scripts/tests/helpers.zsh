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

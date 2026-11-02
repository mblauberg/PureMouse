# release.sh and make-dmg.sh: the version and tree guards in a throwaway git repository, the
# notarisation steps against a fake xcrun and codesign, and the dmg itself with the real hdiutil.
# The build is always a stub: nothing here compiles Swift or signs with a real identity.

# release_repo_init: script_repo made a git repository (in $repo), not yet committed.
release_repo_init() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    unset NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID PUREMOUSE_VERSION DMG_MAX_BYTES INSTALLED_MAX_BYTES
    # No test may reach the real keychain or home.
    export PUREMOUSE_SIGN_IDENTITY=- HOME=$tmp/home
    repo=$(script_repo)
    cp $root/.gitignore $repo/
    git -C $repo init -q
}

# release_repo_commit [tag...]: commits everything in $repo and tags the commit as given.
release_repo_commit() {
    git -C $repo add -A
    git -C $repo commit -q -m scripts
    local tag
    for tag; do git -C $repo tag $tag; done
}

# release_repo [tag...]: both, for a test that needs no stubs.
release_repo() {
    release_repo_init
    release_repo_commit "$@"
}

# tripwire_build <repo>: a build-app.sh that fails the test if a guard let the build start.
tripwire_build() {
    print -r -- '#!/bin/zsh
print -u2 "THE BUILD RAN"
exit 1' > $1/scripts/build-app.sh
}

# expect_release_refused <repo> <text> <release.sh arguments...>: release.sh must fail without
# building, and say <text>.
expect_release_refused() {
    local repo=$1 text=$2 output; shift 2
    tripwire_build $repo
    if output=$($repo/scripts/release.sh "$@" 2>&1); then
        print -u2 -- "release.sh $* succeeded"
        return 1
    fi
    [[ $output != *'THE BUILD RAN'* ]] || { print -u2 -- "the build ran: $output"; return 1; }
    [[ $output == *$text* ]] || { print -u2 -- "expected '$text' in: $output"; return 1; }
}

test_release_refuses_an_untagged_tree() {
    local repo
    release_repo
    expect_release_refused $repo 'HEAD is not tagged'
}

test_release_refuses_tags_that_are_not_release_versions() {
    local repo tag
    for tag in v1.2 v1.2.3-beta v1.2.3-rc; do
        rm -rf $tmp/repo
        release_repo $tag
        expect_release_refused $repo 'no tag on HEAD is vX.Y.Z or vX.Y.Z-rc.N' || return 1
    done
}

test_release_refuses_two_release_tags() {
    local repo
    release_repo v1.2.3 v1.2.4
    expect_release_refused $repo 'more than one release tag'
}

test_release_refuses_a_version_without_a_dry_run() {
    local repo
    release_repo v1.2.3
    expect_release_refused $repo '--version is only for a --dry-run' --version 1.2.3
    expect_release_refused $repo '--version is only for a --dry-run' --version ''
}

test_dry_run_refuses_an_untagged_tree_without_a_version() {
    local repo
    release_repo
    expect_release_refused $repo 'HEAD is not tagged' --dry-run
}

test_dry_run_refuses_a_version_that_is_not_synthetic() {
    local repo
    release_repo
    expect_release_refused $repo 'must be 0.0.0-ci.<shortsha>' --dry-run --version 1.2.3
}

test_release_refuses_a_dirty_tree() {
    local repo
    release_repo v1.2.3
    print extra > $repo/untracked.txt
    expect_release_refused $repo 'working tree is not clean'
}

# release_flow [sign identity] [fixture]: a repo tagged ${flow_tags-v1.2.3} with a stub build and
# verify, fake codesign (which reports <fixture> for `codesign -dvv`), a fake xcrun whose stapler
# leaves a STAPLED file in what it staples, and the real hdiutil.
release_flow() {
    : ${flow_tags=v1.2.3}
    release_repo_init
    stub_build_app $repo
    # The verifier passes, except that FAKE_MOUNTED_BUNDLE_FAILS makes it reject the bundle inside
    # the mounted dmg (the only one named by an absolute path).
    print -r -- '#!/bin/zsh
[[ -z ${FAKE_MOUNTED_BUNDLE_FAILS:-} || $1 != /* ]] || { print -u2 "verify: the bundle in the dmg is broken"; exit 1; }
exit 0' > $repo/scripts/verify-bundle.sh
    release_repo_commit $flow_tags
    fake_command codesign "[[ \$* == *-dvv* ]] && cat $fixtures/${2:-codesign-developer-id.txt}
exit 0"
    # notarytool's JSON is on stdout; its progress noise on stderr must not be mistaken for it.
    fake_command xcrun 'print -r -- "$@" >> "${0:A:h}/xcrun.log"
case "$1 $2" in
    "notarytool submit")
        print -u2 -- "Conducting pre-submission checks... {not json}"
        print -r -- "{\"id\":\"fake-id\",\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\"}" ;;
    "notarytool log") print "apple says: the binary is not signed" ;;
    "stapler staple") [[ -d $3 ]] && touch "$3/STAPLED" ;;
esac
exit 0'
    export PUREMOUSE_SIGN_IDENTITY=${1:-Developer ID Application: Example Person (ABCDE12345)}
}

set_notary_credentials() {
    : > $tmp/AuthKey.p8
    export NOTARY_KEY_PATH=$tmp/AuthKey.p8 NOTARY_KEY_ID=KEYID12345 NOTARY_ISSUER_ID=issuer-uuid
}

test_release_notarises_and_staples_the_app_then_the_dmg() {
    local repo output
    release_flow
    set_notary_credentials
    output=$($repo/scripts/release.sh 2>&1) || { print -u2 -- $output; return 1; }
    local calls=(${(f)"$(<$tmp/fakes/xcrun.log)"})
    [[ $#calls == 4 ]] || { print -u2 -- "xcrun calls: ${(F)calls}"; return 1; }
    [[ $calls[1] == "notarytool submit "*"/PureMouse.zip --key $tmp/AuthKey.p8 --key-id KEYID12345 --issuer issuer-uuid --wait"* ]] || { print -u2 -- $calls[1]; return 1; }
    [[ $calls[2] == "stapler staple .build/app/PureMouse.app" ]] || { print -u2 -- $calls[2]; return 1; }
    [[ $calls[3] == "notarytool submit .build/dist/PureMouse-1.2.3.dmg --key "* ]] || { print -u2 -- $calls[3]; return 1; }
    [[ $calls[4] == "stapler staple .build/dist/PureMouse-1.2.3.dmg" ]] || { print -u2 -- $calls[4]; return 1; }
    (cd $repo/.build/dist && shasum -a 256 -c SHA256SUMS >/dev/null)
    [[ $(<$repo/build-args.log) == "--universal --version 1.2.3 --timestamp" ]] || { print -u2 -- "build ran with: $(<$repo/build-args.log)"; return 1; }
    # The app went into the dmg after it was stapled: the dmg's copy carries what stapling left.
    expect "the dmg holds the stapled app" with_dmg_mounted $repo/.build/dist/PureMouse-1.2.3.dmg mounted_has PureMouse.app/STAPLED
}

test_release_without_notary_credentials_skips_notarisation() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    output=$($repo/scripts/release.sh 2>&1) || { print -u2 -- $output; return 1; }
    [[ $output == *'skipping notarisation'* ]] || { print -u2 -- $output; return 1; }
    expect "xcrun was not run" test ! -e $tmp/fakes/xcrun.log
    expect "the dmg and checksum exist" test -f $repo/.build/dist/PureMouse-1.2.3.dmg -a -f $repo/.build/dist/SHA256SUMS
}

test_release_with_some_notary_credentials_names_the_missing_ones() {
    local repo output
    release_flow
    set_notary_credentials
    unset NOTARY_KEY_ID
    if output=$($repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'missing NOTARY_KEY_ID'* && $output != *NOTARY_ISSUER_ID* ]] || { print -u2 -- $output; return 1; }
    unset NOTARY_ISSUER_ID
    if output=$($repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'missing NOTARY_KEY_ID, NOTARY_ISSUER_ID'* ]] || { print -u2 -- $output; return 1; }
    expect "nothing was built" test ! -e $repo/.build
}

test_release_signed_with_a_developer_id_needs_notary_credentials() {
    local repo output
    release_flow
    if output=$($repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'signed with a Developer ID, so it must be notarised'* ]] || { print -u2 -- $output; return 1; }
    expect "no dmg was made" test ! -e $repo/.build/dist/PureMouse-1.2.3.dmg
}

test_release_prints_the_notary_log_when_notarisation_is_invalid() {
    local repo output
    release_flow
    set_notary_credentials
    if output=$(FAKE_NOTARY_STATUS=Invalid $repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'apple says: the binary is not signed'* && $output == *'(Invalid)'* ]] || { print -u2 -- $output; return 1; }
    expect "the log was asked for by submission id" grep -q '^notarytool log fake-id ' $tmp/fakes/xcrun.log
    expect "nothing was stapled" test -z "$(grep '^stapler' $tmp/fakes/xcrun.log)"
    expect "no dmg was made" test ! -e $repo/.build/dist/PureMouse-1.2.3.dmg
}

test_dry_run_on_an_untagged_tree_makes_the_dmg_and_checksum_without_notarising() {
    local repo output flow_tags=
    release_flow
    set_notary_credentials
    output=$($repo/scripts/release.sh --dry-run --version 0.0.0-ci.abc1234 2>&1) || { print -u2 -- $output; return 1; }
    expect "xcrun was not run" test ! -e $tmp/fakes/xcrun.log
    expect "the dmg exists" test -f $repo/.build/dist/PureMouse-0.0.0-ci.abc1234.dmg
    [[ $(<$repo/build-args.log) == "--universal --version 0.0.0-ci.abc1234" ]] || { print -u2 -- "build ran with: $(<$repo/build-args.log)"; return 1; }
    (cd $repo/.build/dist && shasum -a 256 -c SHA256SUMS >/dev/null)
}

test_dry_run_on_a_release_candidate_tag_takes_its_version() {
    local repo output flow_tags=v1.2.3-rc.1
    release_flow
    output=$($repo/scripts/release.sh --dry-run 2>&1) || { print -u2 -- $output; return 1; }
    expect "the dmg is named by the tag" test -f $repo/.build/dist/PureMouse-1.2.3-rc.1.dmg
}

test_release_checks_both_size_budgets() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    if output=$(DMG_MAX_BYTES=1 $repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'dmg size '*'allowed 1 bytes'* ]] || { print -u2 -- $output; return 1; }
    expect "no checksum is written for an oversized dmg" test ! -e $repo/.build/dist/SHA256SUMS
    if output=$(INSTALLED_MAX_BYTES=1 $repo/scripts/release.sh --dry-run 2>&1); then return 1; fi
    [[ $output == *'installed size '*'allowed 1 bytes'* ]] || { print -u2 -- $output; return 1; }
}

# mounted_has <mount point> <path>: for with_dmg_mounted.
mounted_has() { test -e $1/$2 }

mounted_applications_link() { test "$(readlink $1/Applications)" = /Applications }

test_dmg_is_compressed_and_holds_the_app_and_an_applications_link() {
    local app=$(stand_in_app $tmp 1.2.3) dmg=$tmp/out.dmg
    scripts/make-dmg.sh $app $dmg >/dev/null
    hdiutil imageinfo $dmg | grep -q 'Format: ULFO' || { print -u2 -- "not a ULFO image"; return 1; }
    expect "the dmg holds PureMouse.app" with_dmg_mounted $dmg mounted_has PureMouse.app
    expect "the dmg has an Applications link" with_dmg_mounted $dmg mounted_applications_link
}

# A hdiutil that fails its first two `create`s, as it does when the machine is busy.
test_dmg_is_made_on_the_third_try() {
    local app=$(stand_in_app $tmp 1.2.3)
    fake_command hdiutil "if [[ \$1 == create ]]; then
    print x >> $tmp/creates
    (( \$(wc -l < $tmp/creates) > 2 )) || exit 1
fi
exec /usr/bin/hdiutil \"\$@\""
    scripts/make-dmg.sh $app $tmp/out.dmg >/dev/null 2>&1
    expect "the dmg exists" test -f $tmp/out.dmg
    [[ $(wc -l < $tmp/creates) -eq 3 ]] || { print -u2 -- "create ran $(wc -l < $tmp/creates) times"; return 1; }
}

test_dmg_fails_after_three_tries() {
    local app=$(stand_in_app $tmp 1.2.3) output
    fake_command hdiutil '[[ $1 == create ]] && exit 1
exec /usr/bin/hdiutil "$@"'
    if output=$(scripts/make-dmg.sh $app $tmp/out.dmg 2>&1); then return 1; fi
    [[ $output == *'failed three times'* ]]
}

# A hdiutil that only pretends: it logs attach and detach, and a plain detach fails, as it does
# when something still has the volume open.
fake_attach_only_hdiutil() {
    fake_command hdiutil 'print -r -- "$*" >> "${0:A:h}/hdiutil.log"
[[ $1 == detach && $* != *-force* ]] && exit 1
exit 0'
}

# run_mounted <body...>: runs with_dmg_mounted from lib.zsh in a script of its own, as release.sh
# does, calling the shell function `body`; prints nothing, leaves $tmp/fakes/hdiutil.log.
run_mounted() {
    TMPDIR=$tmp zsh -c 'source "$1/scripts/lib.zsh"; set -e; body() { '"$1"' }; with_dmg_mounted /nowhere.dmg body; print finished' zsh $root
}

test_dmg_is_detached_with_force_and_its_directory_removed_after_the_command_fails() {
    fake_attach_only_hdiutil
    if run_mounted 'return 3' >/dev/null 2>&1; then return 1; fi
    local calls=(${(f)"$(<$tmp/fakes/hdiutil.log)"})
    [[ $calls[1] == "attach "* && $calls[2] == "detach -quiet "* && $calls[3] == "detach -quiet -force "* ]] ||
        { print -u2 -- "hdiutil calls: ${(F)calls}"; return 1; }
    expect "the mount directory is gone" test -z "$(ls -A $tmp | grep -v '^fakes$')"
}

test_dmg_is_detached_when_the_command_exits_the_script() {
    fake_attach_only_hdiutil
    if run_mounted 'print -u2 stopping; exit 7' >/dev/null 2>&1; then return 1; fi
    expect "it was detached" grep -q '^detach ' $tmp/fakes/hdiutil.log
    expect "the mount directory is gone" test -z "$(ls -A $tmp | grep -v '^fakes$')"
}

test_dmg_is_detached_when_the_script_is_terminated_during_the_command() {
    fake_attach_only_hdiutil
    local signal code
    for signal in TERM HUP INT; do
        : > $tmp/fakes/hdiutil.log
        code=0
        run_mounted "kill -$signal \$\$; sleep 5" >/dev/null 2>&1 || code=$?
        (( code > 128 )) || { print -u2 -- "$signal: exit status $code"; return 1; }
        grep -q '^detach ' $tmp/fakes/hdiutil.log || { print -u2 -- "$signal left the image attached"; return 1; }
        test -z "$(ls -A $tmp | grep -v '^fakes$')" || { print -u2 -- "$signal left the mount directory"; return 1; }
    done
}

test_dmg_that_will_not_mount_leaves_nothing_behind() {
    fake_command hdiutil 'print -r -- "$*" >> "${0:A:h}/hdiutil.log"
exit 1'
    if run_mounted 'print ran' >$tmp/out 2>&1; then return 1; fi
    expect "the command did not run" test -z "$(grep ran $tmp/out)"
    expect "the mount directory is gone" test -z "$(ls -A $tmp | grep -v -e '^fakes$' -e '^out$')"
}

test_release_refuses_when_git_cannot_report_the_tree_status() {
    local repo
    release_repo v1.2.3
    print garbage > $repo/.git/index
    expect_release_refused $repo 'git status failed'
}

test_release_stops_when_the_bundle_in_the_dmg_does_not_verify() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    if output=$(FAKE_MOUNTED_BUNDLE_FAILS=1 $repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'the bundle in the dmg is broken'* && $output == *"the dmg's PureMouse.app does not verify"* ]] ||
        { print -u2 -- $output; return 1; }
    expect "no checksum is published" test ! -e $repo/.build/dist/SHA256SUMS
    expect "the sizes were not checked after it" test -z "$(print -r -- $output | grep 'dmg size')"
}

test_release_clears_the_images_an_earlier_run_left_beside_its_checksum() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    output=$($repo/scripts/release.sh --dry-run --version 0.0.0-ci.abc1234 2>&1) || { print -u2 -- $output; return 1; }
    expect "the dry run made its dmg" test -f $repo/.build/dist/PureMouse-0.0.0-ci.abc1234.dmg
    rm $repo/build-args.log   # the stub build's log, which would make the tree unclean
    output=$($repo/scripts/release.sh 2>&1) || { print -u2 -- $output; return 1; }
    local images=($repo/.build/dist/*.dmg(N:t))
    [[ $images == PureMouse-1.2.3.dmg ]] || { print -u2 -- "dist holds: $images"; return 1; }
    [[ $(awk '{print $2}' $repo/.build/dist/SHA256SUMS) == PureMouse-1.2.3.dmg ]] || { print -u2 -- "$(<$repo/.build/dist/SHA256SUMS)"; return 1; }
}

test_release_refuses_a_symlinked_dist_and_leaves_what_it_points_at() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    mkdir -p $tmp/elsewhere $repo/.build
    touch $tmp/elsewhere/PureMouse-important.dmg $tmp/elsewhere/SHA256SUMS
    ln -s $tmp/elsewhere $repo/.build/dist
    if output=$($repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'.build/dist is a symlink'* ]] || { print -u2 -- $output; return 1; }
    expect "the files outside survive" test -f $tmp/elsewhere/PureMouse-important.dmg -a -f $tmp/elsewhere/SHA256SUMS
    expect "nothing was built" test ! -e $repo/.build/app
}

test_release_refuses_a_symlinked_notary_directory_and_leaves_what_it_points_at() {
    local repo output
    release_flow PureMouse codesign-self-signed.txt
    mkdir -p $tmp/elsewhere $repo/.build
    touch $tmp/elsewhere/keep
    ln -s $tmp/elsewhere $repo/.build/notary
    if output=$($repo/scripts/release.sh 2>&1); then return 1; fi
    [[ $output == *'.build/notary is a symlink'* ]] || { print -u2 -- $output; return 1; }
    expect "the file outside survives" test -f $tmp/elsewhere/keep
}

# A script that sets its own TERM and HUP traps, runs with_dmg_mounted, then is signalled.
test_a_callers_signal_traps_survive_with_dmg_mounted() {
    fake_command hdiutil 'exit 0'
    local output
    output=$(TMPDIR=$tmp zsh -c 'source "$1/scripts/lib.zsh"
trap "print caller-term; exit 0" TERM
trap "print caller-hup; exit 0" HUP
body() { true }
with_dmg_mounted /nowhere.dmg body
kill -TERM $$; sleep 5; print not-trapped' zsh $root 2>&1)
    [[ $output == caller-term ]] || { print -u2 -- "got: $output"; return 1; }
}

test_a_dmg_that_cannot_be_detached_fails_even_when_its_command_passes() {
    fake_command hdiutil '[[ $1 == detach ]] && exit 1
exit 0'
    local output code=0
    output=$(run_mounted 'true' 2>&1) || code=$?
    (( code )) || { print -u2 -- "succeeded: $output"; return 1; }
    [[ $output == *'could not unmount'*'hdiutil detach -force'* && $output != *finished* ]] || { print -u2 -- $output; return 1; }
}

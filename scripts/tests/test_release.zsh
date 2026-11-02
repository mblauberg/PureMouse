# release.sh and make-dmg.sh: the version and tree guards in a throwaway git repository, the
# notarisation steps against a fake xcrun and codesign, and the dmg itself with the real hdiutil.
# The build is always a stub: nothing here compiles Swift or signs with a real identity.

# release_repo_init: script_repo made a git repository (in $repo), not yet committed.
release_repo_init() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    unset NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID PUREMOUSE_VERSION PUREMOUSE_SIGN_IDENTITY
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

# release_flow [sign identity] [fixture]: a tagged v1.2.3 repo with a stub build and verify, fake
# codesign (which reports <fixture> for `codesign -dvv`), fake xcrun and the real hdiutil.
release_flow() {
    release_repo_init
    stub_build_app $repo
    print -r -- '#!/bin/zsh
exit 0' > $repo/scripts/verify-bundle.sh
    release_repo_commit v1.2.3
    mkdir -p $tmp/fakes
    print -r -- "#!/bin/zsh
[[ \$* == *-dvv* ]] && cat $fixtures/${2:-codesign-developer-id.txt}
exit 0" > $tmp/fakes/codesign
    print -r -- '#!/bin/zsh
print -r -- "$@" >> "${0:A:h}/xcrun.log"
case "$1 $2" in
    "notarytool submit") print -r -- "{\"id\":\"fake-id\",\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\"}" ;;
    "notarytool log") print "apple says: the binary is not signed" ;;
esac
exit 0' > $tmp/fakes/xcrun
    chmod +x $tmp/fakes/{codesign,xcrun}
    export PATH=$tmp/fakes:$PATH PUREMOUSE_SIGN_IDENTITY=${1:-Developer ID Application: Example Person (ABCDE12345)}
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
    unset NOTARY_KEY_ID NOTARY_ISSUER_ID
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
    expect "no dmg was made" test ! -e $repo/.build/dist/PureMouse-1.2.3.dmg
}

test_dry_run_never_notarises_and_names_the_dmg_by_its_version() {
    local repo output
    release_flow
    set_notary_credentials
    output=$($repo/scripts/release.sh --dry-run --version 0.0.0-ci.abc1234 2>&1) || { print -u2 -- $output; return 1; }
    expect "xcrun was not run" test ! -e $tmp/fakes/xcrun.log
    expect "the dmg exists" test -f $repo/.build/dist/PureMouse-0.0.0-ci.abc1234.dmg
}

test_dmg_is_compressed_and_holds_the_app_and_an_applications_link() {
    local app=$(stand_in_app $tmp 1.2.3) dmg=$tmp/out.dmg mount=$tmp/mount
    scripts/make-dmg.sh $app $dmg >/dev/null
    hdiutil imageinfo $dmg | grep -q 'Format: ULFO' || { print -u2 -- "not a ULFO image"; return 1; }
    mkdir $mount
    hdiutil attach -nobrowse -readonly -noverify -mountpoint $mount $dmg >/dev/null
    local problems=()
    [[ -d $mount/PureMouse.app ]] || problems+="no PureMouse.app"
    [[ $(readlink $mount/Applications) == /Applications ]] || problems+="no Applications link"
    hdiutil detach -quiet $mount
    (( ! $#problems )) || { print -u2 -- ${(j:, :)problems}; return 1; }
}

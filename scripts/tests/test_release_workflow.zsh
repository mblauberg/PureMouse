# Exercise the actual workflow shell blocks with fake commands and throwaway credentials.
workflow_block() {
    awk -v name="$1" '
        $0 == "      - name: " name { found=1; next }
        found && /^      - / { exit }
        found && /^        run: \|/ { body=1; next }
        found && body { sub(/^          /, ""); print }
    ' "$root/.github/workflows/release.yml"
}

workflow_fixture() {
    mkdir -p "$tmp/bin" "$tmp/repo/scripts" "$tmp/runner" "$tmp/repo/.build/notary"
    workflow_block 'Verify tag and main ancestry' > "$tmp/guard"
    workflow_block 'Sign and build release' > "$tmp/build"
    [[ -s "$tmp/guard" && -s "$tmp/build" ]]
    cat > "$tmp/bin/git" <<'SCRIPT'
#!/bin/bash
[[ ${OFF_MAIN:-0} == 0 ]]
SCRIPT
    cat > "$tmp/bin/security" <<'SCRIPT'
#!/bin/bash
echo "$1" >> "$RUNNER_TEMP/security-calls"
[[ $1 != import || ${IMPORT_FAIL:-0} == 0 ]]
SCRIPT
    cat > "$tmp/repo/scripts/release.sh" <<'SCRIPT'
#!/bin/bash
printf '%s' "$PUREMOUSE_SIGN_IDENTITY" > "$RUNNER_TEMP/identity"
echo "release diagnostics"
exit "${RELEASE_STATUS:-0}"
SCRIPT
    chmod +x "$tmp/bin/"* "$tmp/repo/scripts/release.sh"
    export PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/runner" GITHUB_STEP_SUMMARY="$tmp/summary"
    export TAG=v1.2.3 SIGNING_CERT_P12_BASE64= SIGNING_CERT_PASSWORD= SIGNING_IDENTITY_NAME=
    export NOTARY_API_KEY_P8_BASE64= NOTARY_KEY_ID= NOTARY_ISSUER_ID=
}

workflow_build() { (cd "$tmp/repo" && bash "$tmp/build"); }

test_release_workflow_off_main_and_invalid_tags_fail_before_credentials() {
    workflow_fixture
    if OFF_MAIN=1 bash "$tmp/guard" >/dev/null 2>&1; then return 1; fi
    if TAG=v1.2.3-beta bash "$tmp/guard" >/dev/null 2>&1; then return 1; fi
    [[ ! -e "$RUNNER_TEMP/security-calls" ]]
    TAG=v1.2.3-rc.1 bash "$tmp/guard"
}

test_release_workflow_stable_requires_signing_and_rc_is_explicitly_adhoc() {
    workflow_fixture
    if workflow_build >/dev/null 2>&1; then return 1; fi
    [[ ! -e "$RUNNER_TEMP/identity" && ! -e "$RUNNER_TEMP/puremouse-release" ]]
    export TAG=v1.2.3-rc.1
    workflow_build
    [[ $(<"$RUNNER_TEMP/identity") == '-' ]]
    grep -q 'ad hoc signing' "$GITHUB_STEP_SUMMARY"
}

test_release_workflow_cleanup_and_exit_status_on_success_and_failure() {
    workflow_fixture
    export SIGNING_CERT_P12_BASE64=cDEy SIGNING_CERT_PASSWORD=secret-password SIGNING_IDENTITY_NAME=PureMouse
    export NOTARY_API_KEY_P8_BASE64=cDg= NOTARY_KEY_ID=key-id NOTARY_ISSUER_ID=issuer-id
    local output rc
    output=$(workflow_build 2>&1)
    [[ $(<"$RUNNER_TEMP/identity") == PureMouse ]]
    grep -q '^set-keychain-settings$' "$RUNNER_TEMP/security-calls"
    [[ ! -e "$RUNNER_TEMP/puremouse-release" && ! -e "$tmp/repo/.build/notary" ]]
    grep -q '^set-key-partition-list$' "$RUNNER_TEMP/security-calls"
    grep -q '^delete-keychain$' "$RUNNER_TEMP/security-calls"
    rc=0
    output=$(RELEASE_STATUS=23 workflow_build 2>&1) || rc=$?
    [[ $rc == 23 && $output == *'release diagnostics'* && ! -e "$RUNNER_TEMP/puremouse-release" ]]
    rc=0
    IMPORT_FAIL=1 workflow_build >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 && ! -e "$RUNNER_TEMP/puremouse-release" ]]
}

test_release_workflow_rejects_partial_credentials() {
    workflow_fixture
    export TAG=v1.2.3-rc.1 SIGNING_CERT_P12_BASE64=cDEy
    if workflow_build >/dev/null 2>&1; then return 1; fi
    export SIGNING_CERT_P12_BASE64= NOTARY_KEY_ID=key-id
    if workflow_build >/dev/null 2>&1; then return 1; fi
    [[ ! -e "$RUNNER_TEMP/identity" && ! -e "$RUNNER_TEMP/puremouse-release" ]]
}

test_release_workflow_checks_real_git_ancestry() {
    workflow_fixture
    local repo="$tmp/history"
    /usr/bin/git init -q "$repo"
    /usr/bin/git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm base --allow-empty
    /usr/bin/git -C "$repo" update-ref refs/remotes/origin/main HEAD
    (cd "$repo" && PATH=/usr/bin:/bin TAG=v1.2.3 bash "$tmp/guard")
    /usr/bin/git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm outside --allow-empty
    if (cd "$repo" && PATH=/usr/bin:/bin TAG=v1.2.3 bash "$tmp/guard" >/dev/null 2>&1); then return 1; fi
}

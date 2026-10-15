#!/bin/zsh
# Builds PureMouse, installs it as /Applications/PureMouse.app and (re)starts its login agent.
# Arguments go to build-app.sh.
set -euo pipefail
cd "${0:A:h}/.."

label=io.github.mblauberg.puremouse
app=/Applications/PureMouse.app
staged=/Applications/.PureMouse.app.new
previous=/Applications/.PureMouse.app.old
scripts/build-app.sh "$@"

# Stop the running agent before touching its files: replacing a running binary can get it
# killed for an invalid signature before it restores the mouse. bootout returns before the old
# instance has finished restoring, so wait for it to go.
launchctl bootout gui/$UID/$label 2>/dev/null || true
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done
if launchctl print gui/$UID/$label >/dev/null 2>&1; then
    echo "PureMouse is still running, so it was not replaced; try: launchctl bootout gui/$UID/$label" >&2
    exit 1
fi

# Copy the new app alongside the old one and check it before swapping, so a failed copy leaves
# the installed app in place.
trap 'rm -rf $staged' EXIT
rm -rf $staged $previous
ditto .build/app/PureMouse.app $staged
codesign --verify --strict $staged
[[ -e $app ]] && mv $app $previous
if ! mv $staged $app; then
    [[ -e $previous ]] && mv $previous $app
    echo "could not move the new PureMouse into place; kept the installed one" >&2
    exit 1
fi
rm -rf $previous
$app/Contents/MacOS/puremouse register
echo "Log: ~/Library/Logs/PureMouse.log"

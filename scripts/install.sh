#!/bin/zsh
# Builds PureMouse, installs it as /Applications/PureMouse.app and (re)starts its login agent.
# Arguments go to build-app.sh.
set -euo pipefail
cd "${0:A:h}/.."

label=io.github.mblauberg.puremouse
app=/Applications/PureMouse.app
scripts/build-app.sh "$@"

# Stop the running agent before touching its files: replacing a running binary can get it
# killed for an invalid signature before it restores the mouse. bootout returns before the old
# instance has finished restoring, so wait for it to go.
launchctl bootout gui/$UID/$label 2>/dev/null || true
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done

rm -rf $app
ditto .build/app/PureMouse.app $app
$app/Contents/MacOS/puremouse register
echo "Log: ~/Library/Logs/PureMouse.log"

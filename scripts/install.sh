#!/bin/zsh
# Builds mxd, installs it as /Applications/mxd.app and (re)starts its login agent. Arguments go
# to build-app.sh.
set -euo pipefail
cd "${0:A:h}/.."

label=local.mxd
app=/Applications/mxd.app
scripts/build-app.sh "$@"

# Stop the running agent before touching its files: replacing a running binary can get it
# killed for an invalid signature before it restores the mouse.
legacy=~/Library/LaunchAgents/$label.plist  # written by installs before the app registered itself
if [[ -f $legacy ]]; then
    launchctl bootout gui/$UID/$label 2>/dev/null || true
    rm $legacy
elif [[ -x $app/Contents/MacOS/mxd ]]; then
    $app/Contents/MacOS/mxd unregister >/dev/null || true
fi
# Stopping returns before the old instance has finished restoring the mouse, so wait for it.
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done

rm -rf $app
ditto .build/app/mxd.app $app
$app/Contents/MacOS/mxd register
echo "Log: ~/Library/Logs/mxd.log"

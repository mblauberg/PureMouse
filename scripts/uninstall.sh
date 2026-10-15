#!/bin/zsh
# Stops mxd and removes the app and its login agent. Keeps ~/.config/mxd.
set -euo pipefail
label=local.mxd
app=/Applications/mxd.app
[[ -x $app/Contents/MacOS/mxd ]] && { $app/Contents/MacOS/mxd unregister >/dev/null || true }
launchctl bootout gui/$UID/$label 2>/dev/null || true  # installs before the app registered itself
rm -f ~/Library/LaunchAgents/$label.plist
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done
rm -rf $app
echo "mxd removed. Config kept at ~/.config/mxd/config.json"

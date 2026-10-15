#!/bin/zsh
# Stops mxd and removes the app and its login agent. Keeps ~/.config/mxd.
set -euo pipefail
label=local.mxd
launchctl bootout gui/$UID/$label 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$label.plist
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done
rm -rf /Applications/mxd.app
echo "mxd removed. Config kept at ~/.config/mxd/config.json"

#!/bin/zsh
# Stops PureMouse and removes the app and its login agent. Keeps ~/.config/puremouse.
set -euo pipefail
label=io.github.mblauberg.puremouse
launchctl bootout gui/$UID/$label 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$label.plist
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done
rm -rf /Applications/PureMouse.app
echo "PureMouse removed. Config kept at ~/.config/puremouse/config.json"

#!/bin/zsh
# Stops PureMouse and removes the app and its login agent. Keeps ~/.config/puremouse.
set -euo pipefail
label=io.github.mblauberg.puremouse
launchctl bootout gui/$UID/$label 2>/dev/null || true
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done
# Deleting a running agent's files would leave it unable to restart or be cleanly stopped.
if launchctl print gui/$UID/$label >/dev/null 2>&1; then
    echo "PureMouse is still running, so nothing was removed; try: launchctl bootout gui/$UID/$label" >&2
    exit 1
fi
rm -f ~/Library/LaunchAgents/$label.plist
rm -rf /Applications/PureMouse.app
echo "PureMouse removed. Config kept at ~/.config/puremouse/config.json"

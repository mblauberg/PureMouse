#!/bin/zsh
# Stops mxd and removes the app and login agent. Keeps ~/.config/mxd.
set -euo pipefail
label=local.mxd
launchctl bootout gui/$UID/$label 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$label.plist
rm -rf /Applications/mxd.app
echo "mxd removed. Config kept at ~/.config/mxd/config.json"

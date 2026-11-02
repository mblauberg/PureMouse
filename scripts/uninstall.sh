#!/bin/zsh
# Stops PureMouse, quits Settings and removes the app and its login agents (the daemon's and the
# menu bar app's).
# Keeps ~/.config/puremouse.
set -euo pipefail
source "${0:A:h}/lib.zsh"
# Deleting a running agent's files would leave it unable to restart or be cleanly stopped.
stop_agents "nothing was removed"
for component in $components; do
    rm -f ~/Library/LaunchAgents/$(component_id "$component").plist
done
rm -rf $install_dir/PureMouse.app
echo "PureMouse removed. Config kept at ~/.config/puremouse/config.json"

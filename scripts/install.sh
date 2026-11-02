#!/bin/zsh
# Builds PureMouse, installs it as /Applications/PureMouse.app and (re)starts its login agent.
# Arguments go to build-app.sh.
set -euo pipefail
source "${0:A:h}/lib.zsh"
cd $root

app=$install_dir/PureMouse.app
staged=$install_dir/.PureMouse.app.new
previous=$install_dir/.PureMouse.app.old
scripts/build-app.sh "$@"

# Stop the menu bar app and the agent before touching their files; register starts them again.
stop_agents "it was not replaced"

# Copy the new app alongside the old one and check it before swapping, so a failed copy or a
# bundle that does not verify leaves the installed app in place.
trap 'rm -rf $staged' EXIT
rm -rf $staged $previous
ditto .build/app/PureMouse.app $staged
scripts/verify-bundle.sh $staged
[[ -e $app ]] && mv $app $previous
if ! mv $staged $app; then
    [[ -e $previous ]] && mv $previous $app
    echo "could not move the new PureMouse into place; kept the installed one" >&2
    exit 1
fi
rm -rf $previous
$app/Contents/MacOS/puremouse register
echo "Log: ~/Library/Logs/PureMouse.log"

#!/bin/zsh
# Builds a release zip of PureMouse.app for Apple silicon and Intel Macs in .build/dist/.
# Sign releases with the same identity every time, or users lose their permission grants on update.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --universal
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' .build/app/PureMouse.app/Contents/Info.plist)
mkdir -p .build/dist
zip=.build/dist/PureMouse-$version.zip
rm -f $zip
ditto -c -k --keepParent .build/app/PureMouse.app $zip
echo "packaged $zip"

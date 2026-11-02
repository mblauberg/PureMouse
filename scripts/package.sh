#!/bin/zsh
# Builds a release zip of PureMouse.app for Apple silicon and Intel Macs in .build/dist/, after
# verify-bundle.sh --release passes on the bundle (so the zip is never made from a bundle that fails).
# Sign releases with the same identity every time, or users lose their permission grants on update.
set -euo pipefail
source "${0:A:h}/lib.zsh"
cd $root

app=.build/app/PureMouse.app
scripts/build-app.sh --universal
scripts/verify-bundle.sh $app --release
version=$(plist_value $app/Contents/Info.plist CFBundleShortVersionString)
mkdir -p .build/dist
zip=.build/dist/PureMouse-$version.zip
rm -f $zip
ditto -c -k --keepParent $app $zip
echo "packaged $zip"

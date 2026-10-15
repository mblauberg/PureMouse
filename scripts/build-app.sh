#!/bin/zsh
# Builds and signs .build/app/PureMouse.app. Used by install.sh and package.sh.
#
#   --universal   one binary for Apple silicon and Intel (release zips); otherwise this Mac's only
#
# Signing: uses the code-signing identity named by PUREMOUSE_SIGN_IDENTITY, else one named
# "PureMouse" if the keychain has it (scripts/make-cert.sh creates it), else ad hoc. macOS ties
# PureMouse's Accessibility and Input Monitoring grants to the signature, so a stable identity keeps
# them across rebuilds and releases; ad hoc needs them granted again after every install.
set -euo pipefail
cd "${0:A:h}/.."

label=io.github.mblauberg.puremouse
app=.build/app/PureMouse.app
minimum=14.0
version=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
version=${version#v}  # tags are v1.2.3; bundle versions are 1.2.3
if [[ -n ${PUREMOUSE_SIGN_IDENTITY:-} ]]; then
    identity=$PUREMOUSE_SIGN_IDENTITY
elif security find-identity -p codesigning | grep -q '"PureMouse"'; then
    identity=PureMouse
else
    identity=-
    echo "No 'PureMouse' code-signing identity (scripts/make-cert.sh): signing ad hoc, so permissions must be granted again"
fi

if [[ ${1:-} == --universal ]]; then
    # Some SwiftPM versions build every triple into the same directory, so copy each slice out.
    mkdir -p .build/slices
    for arch in arm64 x86_64; do
        flags=(-c release --product puremouse --triple $arch-apple-macosx$minimum)
        swift build $flags
        cp "$(swift build $flags --show-bin-path)/puremouse" .build/slices/$arch
    done
    binary=.build/slices/universal
    lipo -create -output $binary .build/slices/{arm64,x86_64}
else
    swift build -c release --product puremouse
    binary="$(swift build -c release --product puremouse --show-bin-path)/puremouse"
fi

rm -rf $app
mkdir -p $app/Contents/{MacOS,Resources}
cp $binary $app/Contents/MacOS/puremouse
cp config.example.json assets/AppIcon.icns $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>PureMouse</string>
  <key>CFBundleExecutable</key><string>puremouse</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$identity" --identifier $label $app
echo "built $app ($version, $(lipo -archs $app/Contents/MacOS/puremouse))"

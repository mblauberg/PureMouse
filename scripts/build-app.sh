#!/bin/zsh
# Builds and signs .build/app/mxd.app. Used by install.sh and package.sh.
#
#   --universal   one binary for Apple silicon and Intel (release zips); otherwise this Mac's only
#
# Signing: uses the code-signing identity named by MXD_SIGN_IDENTITY, else one named "mxd" if
# the keychain has it (scripts/make-cert.sh creates it), else ad hoc. macOS ties mxd's
# Accessibility and Input Monitoring grants to the signature, so a stable identity keeps them
# across rebuilds and releases; ad hoc needs them granted again after every install.
set -euo pipefail
cd "${0:A:h}/.."

label=local.mxd
app=.build/app/mxd.app
minimum=14.0
version=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
if [[ -n ${MXD_SIGN_IDENTITY:-} ]]; then
    identity=$MXD_SIGN_IDENTITY
elif security find-identity -p codesigning | grep -q '"mxd"'; then
    identity=mxd
else
    identity=-
    echo "No 'mxd' code-signing identity (scripts/make-cert.sh): signing ad hoc, so permissions must be granted again"
fi

if [[ ${1:-} == --universal ]]; then
    # Some SwiftPM versions build every triple into the same directory, so copy each slice out.
    mkdir -p .build/slices
    for arch in arm64 x86_64; do
        flags=(-c release --product mxd --triple $arch-apple-macosx$minimum)
        swift build $flags
        cp "$(swift build $flags --show-bin-path)/mxd" .build/slices/$arch
    done
    binary=.build/slices/universal
    lipo -create -output $binary .build/slices/{arm64,x86_64}
else
    swift build -c release --product mxd
    binary="$(swift build -c release --product mxd --show-bin-path)/mxd"
fi

rm -rf $app
mkdir -p $app/Contents/{MacOS,Resources}
cp $binary $app/Contents/MacOS/mxd
cp config.example.json $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>mxd</string>
  <key>CFBundleExecutable</key><string>mxd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$identity" --identifier $label $app
echo "built $app ($version, $(lipo -archs $app/Contents/MacOS/mxd))"

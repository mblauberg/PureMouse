#!/bin/zsh
# Builds and signs .build/app/PureMouse.app, with the menu bar app nested at
# Contents/Library/LoginItems/PureMouse Menu.app. Used by install.sh and package.sh.
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
menu_label=$label.menu
app=.build/app/PureMouse.app
menu_app="$app/Contents/Library/LoginItems/PureMouse Menu.app"
products=(puremouse PureMouseMenu)
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
        for product in $products; do
            flags=(-c release --product $product --triple $arch-apple-macosx$minimum)
            swift build $flags
            cp "$(swift build $flags --show-bin-path)/$product" .build/slices/$product-$arch
        done
    done
    bin=.build/slices
    for product in $products; do
        lipo -create -output $bin/$product .build/slices/$product-{arm64,x86_64}
    done
else
    for product in $products; do
        swift build -c release --product $product
    done
    bin="$(swift build -c release --show-bin-path)"
fi

rm -rf $app
mkdir -p $app/Contents/{MacOS,Resources}
cp $bin/puremouse $app/Contents/MacOS/puremouse
cp config.example.json assets/{Assets.car,AppIcon.icns} $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>PureMouse</string>
  <key>CFBundleExecutable</key><string>puremouse</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST

# The menu bar app: a login item of its own (puremouse register writes its agent).
mkdir -p "$menu_app/Contents/"{MacOS,Resources}
cp $bin/PureMouseMenu "$menu_app/Contents/MacOS/PureMouseMenu"
cp assets/{Assets.car,AppIcon.icns,MenuBarIcon.pdf} "$menu_app/Contents/Resources/"
cat > "$menu_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$menu_label</string>
  <key>CFBundleName</key><string>PureMouse</string>
  <key>CFBundleDisplayName</key><string>PureMouse</string>
  <key>CFBundleExecutable</key><string>PureMouseMenu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Inside out, without --deep: the nested app keeps its own identifier, and the outer signature
# seals it.
codesign --force --sign "$identity" --identifier $menu_label "$menu_app"
codesign --force --sign "$identity" --identifier $label $app
echo "built $app ($version, $(lipo -archs $app/Contents/MacOS/puremouse))"

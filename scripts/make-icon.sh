#!/bin/zsh
# Compiles assets/AppIcon.icon (an Icon Composer document) into what the bundle and README use:
#
#   assets/Assets.car       the adaptive icon: light, dark, clear and tinted on macOS 26 and later
#   assets/AppIcon.icns     the flat fallback for macOS 14 and 15
#   assets/AppIcon.png      README image, light; AppIcon-dark.png for dark mode
#
# Needs Xcode 26 or later (actool, and Icon Composer's ictool). The outputs are committed so that
# building needs neither, so only run this after changing the icon.
set -euo pipefail
cd "${0:A:h}/.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
out=$(mktemp -d)
xcrun actool assets/AppIcon.icon --compile $out --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist $out/partial.plist >/dev/null
cp $out/Assets.car $out/AppIcon.icns assets/
for rendition in Default Dark; do
    png=assets/AppIcon.png
    [[ $rendition == Dark ]] && png=assets/AppIcon-dark.png
    "$ictool" assets/AppIcon.icon --export-image --output-file $png --platform macOS \
        --rendition $rendition --width 256 --height 256 --scale 1 >/dev/null
done
rm -rf $out
echo "compiled assets/Assets.car, AppIcon.icns, AppIcon.png and AppIcon-dark.png"

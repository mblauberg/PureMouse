#!/bin/zsh
# Renders assets/AppIcon.svg into assets/AppIcon.icns (bundled by build-app.sh) and
# assets/AppIcon.png (README). Needs rsvg-convert (`brew install librsvg`); the outputs are
# committed, so only run this after changing the SVG.
set -euo pipefail
cd "${0:A:h}/.."

set=$(mktemp -d)/AppIcon.iconset
mkdir -p $set
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size assets/AppIcon.svg -o $set/icon_${size}x${size}.png
    rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/AppIcon.svg -o $set/icon_${size}x${size}@2x.png
done
iconutil -c icns $set -o assets/AppIcon.icns
rsvg-convert -w 256 -h 256 assets/AppIcon.svg -o assets/AppIcon.png
rm -rf ${set:h}
echo "rendered assets/AppIcon.icns and assets/AppIcon.png"

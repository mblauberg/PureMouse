#!/bin/zsh
# Rebuilds the device art from its sources (assets/silhouettes/source, Python 3 standard library
# only) and the geometry the device card is hit-tested with:
#
#   assets/silhouettes/<family>-<light|dark>.svg and .pdf   the drawings, one per family and look
#   assets/silhouettes/regions.json                          hit cells and part outlines per family
#   Sources/PureMouseSettingsUI/DeviceArtGeometry.swift      the same, as typed Swift data
#
# Needs python3 and rsvg-convert (librsvg), which make-icon.sh uses as well. The outputs are
# committed so that building needs neither, so only run this after changing the art. The PDFs
# differ byte for byte on every run (they carry a creation date); the SVGs, regions.json and the
# Swift file do not, so a run with no art change shows only the PDFs in `git status`.
set -euo pipefail
cd "${0:A:h}/.."

for tool in python3 rsvg-convert; do
    command -v $tool >/dev/null || { echo "make-silhouettes.sh needs $tool" >&2; exit 1 }
done
out=$(mktemp -d)
trap 'rm -rf $out' EXIT
python3 -I -B assets/silhouettes/source/export.py $out >/dev/null
cp $out/*.svg $out/*.pdf $out/regions.json assets/silhouettes/
python3 -I -B assets/silhouettes/source/swift_geometry.py assets/silhouettes/regions.json \
    Sources/PureMouseSettingsUI/DeviceArtGeometry.swift
echo "rebuilt assets/silhouettes (SVG, PDF, regions.json) and DeviceArtGeometry.swift"

#!/bin/zsh
# Builds and signs .build/app/PureMouse.app, with the menu bar app nested at
# Contents/Library/LoginItems/PureMouse Menu.app. Used by install.sh and package.sh.
#
#   --universal      one stripped binary for Apple silicon and Intel (releases); otherwise this
#                    Mac's only, unstripped
#   --version X.Y.Z  the bundle version (or PUREMOUSE_VERSION); otherwise from `git describe`
#
# Signing (sign-bundle.sh, always with the hardened runtime): the identity named by
# PUREMOUSE_SIGN_IDENTITY, else a Developer ID Application identity, else one named "PureMouse"
# (scripts/make-cert.sh), else ad hoc. macOS ties PureMouse's Accessibility and Input Monitoring
# grants to the signature, so a stable identity keeps them across rebuilds and releases; ad hoc
# needs them granted again after every install.
set -euo pipefail
source "${0:A:h}/lib.zsh"
cd $root

app=.build/app/PureMouse.app
products=(puremouse PureMouseMenu)
universal=0
while (( $# )); do
    case $1 in
        --universal) universal=1; shift ;;
        --version) (( $# >= 2 )) || die "--version needs a value"; PUREMOUSE_VERSION=$2; shift 2 ;;
        *) die "usage: build-app.sh [--universal] [--version X.Y.Z]" ;;
    esac
done
version=$(resolve_version)
build=$(resolve_build_number)
identity=$(signing_identity)
if [[ $identity == - ]]; then
    echo "No 'PureMouse' code-signing identity (scripts/make-cert.sh): signing ad hoc, so permissions must be granted again"
fi

if (( universal )); then
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
        # Release builds drop local symbols (about half of each binary); crash reports still name
        # public symbols, and local builds keep everything.
        strip -x $bin/$product
    done
else
    for product in $products; do
        swift build -c release --product $product
    done
    bin="$(swift build -c release --show-bin-path)"
fi

assemble_bundle $bin $app $version $build
scripts/sign-bundle.sh $app --identity "$identity"
echo "built $app ($version, build $build, $(lipo -archs $app/Contents/MacOS/puremouse), signed by $identity)"

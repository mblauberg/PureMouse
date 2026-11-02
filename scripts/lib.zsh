# Shared by the build, sign, verify, install, uninstall and release scripts and their tests: source
# it, do not run it.
#
# Bundle layout, identifiers, the one Info.plist writer, version handling and identity choice live
# here so that every script agrees on them. The identifiers are frozen: macOS keys permission grants
# and launchd keys login agents to them.

root=${${(%):-%x}:A:h:h}
label=io.github.mblauberg.puremouse
menu_label=$label.menu
minimum=14.0
copyright="Copyright © 2026 Michael Blauberg. MIT licence."
category=public.app-category.utilities

# Every signed bundle as "identifier:path inside the app" ("." is the app itself), innermost first:
# sign-bundle.sh signs in this order and verify-bundle.sh checks each one. A new nested bundle is one
# more entry, before the bundle that contains it. Read entries with component_id and component_path.
components=(
    "$menu_label:Contents/Library/LoginItems/PureMouse Menu.app"
    "$label:."
)

die() {
    print -u2 -- "$*"
    exit 1
}

# component_id <component>: the bundle identifier of a `components` entry.
component_id() {
    print -r -- ${1%%:*}
}

# component_path <app> <component>: where that entry's bundle sits in <app>.
component_path() {
    print -r -- ${${:-$1/${2#*:}}%/.}
}

# menu_component: the `components` entry of the nested menu bar app.
menu_component() {
    print -r -- ${(M)components:#$menu_label:*}
}

# Where install.sh puts PureMouse.app and uninstall.sh takes it from. PUREMOUSE_INSTALL_DIR exists
# for the script tests, which must never touch /Applications.
install_dir=${PUREMOUSE_INSTALL_DIR:-/Applications}

# stop_agents <consequence>: boots out every component's login agent (the menu bar app's first, the
# daemon's last; a component without an agent is simply not loaded) and waits until none is running,
# so their files can be replaced or removed. bootout returns before the old instance has finished
# restoring the mouse, and replacing a running binary can get it killed for an invalid signature
# first. Otherwise it dies with "PureMouse is still running, so <consequence>".
stop_agents() {
    local component loaded
    for component in $components; do
        launchctl bootout gui/$UID/$(component_id $component) 2>/dev/null || true
    done
    # The menu bar app may have been started by the Finder rather than launchd.
    pkill -x PureMouseMenu 2>/dev/null || true
    local _
    for _ in {1..50}; do
        loaded=
        for component in $components; do
            ! launchctl print gui/$UID/$(component_id $component) >/dev/null 2>&1 || loaded=$(component_id $component)
        done
        if [[ -z $loaded ]] && ! pgrep -x PureMouseMenu >/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    die "PureMouse is still running, so $1; try: ${loaded:+launchctl bootout gui/$UID/$loaded}${loaded:-pkill -x PureMouseMenu}"
}

# plist_value <plist> <key>: a top-level value, or a non-zero status when the key is missing.
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" $1 2>/dev/null
}

# The bundle version: PUREMOUSE_VERSION when set, else the nearest tag without its `v` (with
# `-N-gSHA` when HEAD is past it, and `-dirty`), else `dev`. Only release checks insist on a clean
# X.Y.Z (release_version_ok).
resolve_version() {
    if [[ -n ${PUREMOUSE_VERSION:-} ]]; then
        print -r -- ${PUREMOUSE_VERSION#v}
        return
    fi
    local described
    described=$(git -C $root describe --tags --always --dirty 2>/dev/null) || described=dev
    print -r -- ${described#v}
}

# CFBundleVersion: the number of commits on HEAD, so it only grows along main (in a full clone; a
# shallow CI checkout counts 1).
resolve_build_number() {
    git -C $root rev-list --count HEAD 2>/dev/null || print 0
}

# A version a release may carry: X.Y.Z or X.Y.Z-rc.N.
release_version_ok() {
    [[ $1 =~ '^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$' ]]
}

# The signing identity, in this order (the one place the order is written down for code; people read
# docs/development.md#signing): PUREMOUSE_SIGN_IDENTITY, else a valid Developer ID Application
# identity, else the self-signed "PureMouse" (scripts/make-cert.sh), else "-" (ad hoc). "PureMouse"
# is untrusted, so it is looked up without -v.
signing_identity() {
    if [[ -n ${PUREMOUSE_SIGN_IDENTITY:-} ]]; then
        print -r -- $PUREMOUSE_SIGN_IDENTITY
        return
    fi
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null |
        grep -o -m 1 '"Developer ID Application: [^"]*"') || true
    if [[ -n $found ]]; then
        print -r -- ${${found#\"}%\"}
    elif security find-identity -p codesigning 2>/dev/null | grep '"PureMouse"' >/dev/null; then
        print PureMouse
    else
        print -- -
    fi
}

# write_info_plist <file> <identifier> <executable> <version> <build> daemon|menu
# The daemon's bundle is background-only; the menu app has a display name and the allocator setting
# its agent also sets (LoginItem.menuDefinition), for Finder launches. Nothing else differs.
write_info_plist() {
    local file=$1 identifier=$2 executable=$3 version=$4 build=$5 role=$6
    local display= background= environment=
    case $role in
        daemon) background=$'\n  <key>LSBackgroundOnly</key><true/>' ;;
        menu)
            display=$'\n  <key>CFBundleDisplayName</key><string>PureMouse</string>'
            environment=$'\n  <key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict>'
            ;;
        *) die "write_info_plist: role must be daemon or menu, not '$role'" ;;
    esac
    cat > $file <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleName</key><string>PureMouse</string>$display
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSApplicationCategoryType</key><string>$category</string>
  <key>NSHumanReadableCopyright</key><string>$copyright</string>
  <key>LSUIElement</key><true/>$background$environment
</dict></plist>
PLIST
}

# assemble_bundle <bin dir> <app> <version> <build>
# Lays out an unsigned PureMouse.app from built `puremouse` and `PureMouseMenu` binaries, with the
# menu bar app nested at Contents/Library/LoginItems (a login item of its own: `puremouse register`
# writes its agent).
assemble_bundle() {
    local bin=$1 app=$2 version=$3 build=$4
    local menu_app=$(component_path $app "$(menu_component)")
    rm -rf $app
    mkdir -p $app/Contents/{MacOS,Resources}
    cp $bin/puremouse $app/Contents/MacOS/puremouse
    cp $root/config.example.json $root/assets/{Assets.car,AppIcon.icns} $app/Contents/Resources/
    write_info_plist $app/Contents/Info.plist $label puremouse $version $build daemon

    make_menu_bundle $bin/PureMouseMenu $menu_app $menu_label $version $build
}

# make_menu_bundle <menu binary> <app> <identifier> <version> <build>
# The menu bar app's bundle, unsigned. assemble_bundle nests it in PureMouse.app; the footprint rig
# (measure-menu.sh) builds its own under another identifier, so it measures the shape that ships.
make_menu_bundle() {
    local binary=$1 menu_app=$2 identifier=$3 version=$4 build=$5
    mkdir -p "$menu_app/Contents/"{MacOS,Resources}
    cp $binary "$menu_app/Contents/MacOS/PureMouseMenu"
    cp $root/assets/{Assets.car,AppIcon.icns,AppIcon.png,AppIcon-dark.png,MenuBarIcon.pdf} \
        "$menu_app/Contents/Resources/"
    write_info_plist "$menu_app/Contents/Info.plist" $identifier PureMouseMenu $version $build menu
}

# check_release_signature <codesign -dvv output> <team ID> <component>
# A release must be signed by a Developer ID Application identity of the expected team. Takes the
# text rather than running codesign, so tests can feed it fixtures.
check_release_signature() {
    local text=$1 team=$2 name=$3 ok=0
    if ! print -r -- $text | grep '^Authority=Developer ID Application: ' >/dev/null; then
        print -u2 -- "$name: not signed by a Developer ID Application identity"
        ok=1
    fi
    if ! print -r -- $text | grep -Fx -- "TeamIdentifier=$team" >/dev/null; then
        print -u2 -- "$name: team is $(print -r -- $text | sed -n 's/^TeamIdentifier=//p'), not $team"
        ok=1
    fi
    return $ok
}

# developer_id_requirement <team ID>
# A code requirement met only by a Developer ID Application certificate of that team, issued under
# Apple's root (the OIDs mark the Developer ID intermediate and leaf), for `codesign --verify -R`.
developer_id_requirement() {
    print -r -- "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$1\""
}

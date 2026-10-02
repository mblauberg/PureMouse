#!/bin/zsh
# Builds mxd, installs it as /Applications/mxd.app and (re)starts it as a login agent
# (launchd starts it at login and restarts it if it ever exits).
#
# Signing: uses the code-signing identity named by MXD_SIGN_IDENTITY, else one named "mxd" if
# the keychain has it. A stable identity lets macOS keep the Accessibility and Input Monitoring
# grants across rebuilds; an ad-hoc signature needs them granted again after every install.
set -euo pipefail
cd "${0:A:h}/.."

label=local.mxd
app=/Applications/mxd.app
agent=~/Library/LaunchAgents/$label.plist
if [[ -n ${MXD_SIGN_IDENTITY:-} ]]; then
    identity=$MXD_SIGN_IDENTITY
elif security find-identity -p codesigning | grep -q '"mxd"'; then
    identity=mxd
else
    identity=-
    echo "No 'mxd' code-signing identity: ad-hoc signing, so permissions must be granted again"
fi

swift build -c release --product mxd

# Stop the running agent before touching its files: replacing a running binary can get it
# killed for an invalid signature before it restores the mouse. bootout returns before the old
# instance has finished restoring, so wait for it to go.
launchctl bootout gui/$UID/$label 2>/dev/null || true
for _ in {1..50}; do
    launchctl print gui/$UID/$label >/dev/null 2>&1 || break
    sleep 0.1
done

mkdir -p $app/Contents/MacOS ~/Library/LaunchAgents ~/Library/Logs ~/.config/mxd
rm -f $app/Contents/MacOS/mxd
cp .build/release/mxd $app/Contents/MacOS/mxd
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>mxd</string>
  <key>CFBundleExecutable</key><string>mxd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(git describe --always --dirty 2>/dev/null || echo dev)</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$identity" --identifier $label $app

[[ -f ~/.config/mxd/config.json ]] || cp config.example.json ~/.config/mxd/config.json

cat > $agent <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/mxd</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>3</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mxd.log</string>
</dict></plist>
PLIST

launchctl bootstrap gui/$UID $agent
echo "mxd installed and running. Log: ~/Library/Logs/mxd.log"

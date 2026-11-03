#!/bin/zsh
# Build the window app, wrap it in a minimal .app bundle, and open it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --product LoopStudioApp
bin="$(swift build -c debug --show-bin-path)/LoopStudioApp"
app=".build/LoopStudio.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/LoopStudioApp"
# The icon: scripts/make-icon.swift draws it into Resources/AppIcon.icns.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LoopStudio</string>
<key>CFBundleExecutable</key><string>LoopStudioApp</string>
<key>CFBundleIdentifier</key><string>app.loopstudio.dev</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LoopStudio records audio from your sound card input.</string>
<key>NSLocalNetworkUsageDescription</key><string>Ableton Link shares the tempo and the beat grid with other apps on your network.</string>
</dict></plist>
PLIST
# A development certificate gives every build the same identity, so macOS keeps the microphone permission.
# Without one, the ad-hoc signature changes with each build and the permission is asked for again.
identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
codesign --force --sign "${identity:--}" "$app" >/dev/null 2>&1 || codesign --force --sign - "$app" >/dev/null 2>&1 || true
# A running copy would only be brought to the front, with the old code. Quit it first: a regular quit, so
# the app saves its project; SIGTERM as the fallback (the app saves on that too).
if pgrep -x LoopStudioApp >/dev/null 2>&1; then
    osascript -e 'tell application "LoopStudioApp" to quit' >/dev/null 2>&1
    for _ in 1 2 3 4 5 6; do pgrep -x LoopStudioApp >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x LoopStudioApp 2>/dev/null && sleep 1
fi
# Start the binary from this shell, not with `open`: an app that LaunchServices opens needs its own
# Local Network grant, and on this Mac macOS never shows that prompt (its UserEventAgent cannot reach
# nehelper: "not platform entitled"), so Link finds no peer on the LAN. A process started from a
# terminal runs under the terminal's grant. `open` afterwards only brings the running app to the front.
nohup "$app/Contents/MacOS/LoopStudioApp" >/dev/null 2>&1 &
pid=$!
disown
# `open` before LaunchServices knows the process starts a second instance (two Link sessions, two
# sockets). Wait until it is registered, up to five seconds; only then bring it to the front.
for _ in $(seq 1 50); do
    if lsappinfo find "pid=$pid" 2>/dev/null | grep -q ASN; then break; fi
    sleep 0.1
done
if lsappinfo find "pid=$pid" 2>/dev/null | grep -q ASN; then
    open "$app"
else
    echo "LoopStudio is running (pid $pid) but not yet registered with LaunchServices; not opened a second time." >&2
fi

#!/bin/zsh
# Build the window app, wrap it in a minimal .app bundle, and open it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --product LoopStudioApp
bin="$(swift build -c debug --show-bin-path)/LoopStudioApp"
app=".build/LoopStudio.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/LoopStudioApp"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LoopStudio</string>
<key>CFBundleExecutable</key><string>LoopStudioApp</string>
<key>CFBundleIdentifier</key><string>app.loopstudio.dev</string>
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
# A running copy would only be brought to the front, with the old code. Quit it first.
pkill -x LoopStudioApp 2>/dev/null && sleep 1
# Start the binary from this shell, not with `open`: an app that LaunchServices opens needs its own
# Local Network grant, and on this Mac macOS never shows that prompt (its UserEventAgent cannot reach
# nehelper: "not platform entitled"), so Link finds no peer on the LAN. A process started from a
# terminal runs under the terminal's grant. `open` afterwards only brings the running app to the front.
nohup "$app/Contents/MacOS/LoopStudioApp" >/dev/null 2>&1 &
disown
sleep 1
open "$app"

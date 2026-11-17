#!/bin/zsh
# Build the release app and put it into /Applications as LoopStudio.app. It does not start the app.
# Usage: scripts/install-app.sh [-j N]
set -euo pipefail
cd "$(dirname "$0")/.."
jobs=()
[ "${1:-}" = "-j" ] && jobs=(-j "$2")
swift build -c release --product LoopStudioApp "${jobs[@]}"
bin="$(swift build -c release --show-bin-path)/LoopStudioApp"
app="/Applications/LoopStudio.app"
stage=".build/LoopStudio-release.app"
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin" "$stage/Contents/MacOS/LoopStudioApp"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$stage/Contents/Resources/AppIcon.icns"
version="$(git describe --tags --always 2>/dev/null || echo 0.1)"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LoopStudio</string>
<key>CFBundleExecutable</key><string>LoopStudioApp</string>
<key>CFBundleIdentifier</key><string>app.loopstudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LoopStudio records audio from your sound card input.</string>
<key>NSLocalNetworkUsageDescription</key><string>Ableton Link shares the tempo and the beat grid with other apps on your network.</string>
</dict></plist>
PLIST
# The same development identity as run-app.sh, so macOS keeps the microphone permission between installs.
identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
codesign --force --sign "${identity:--}" "$stage" >/dev/null 2>&1 || codesign --force --sign - "$stage" >/dev/null 2>&1 || true
# Replace the installed app in one move. A running installed copy keeps running with its old code.
rm -rf "$app"
ditto "$stage" "$app"
echo "installed $app (version $version, build $build)"

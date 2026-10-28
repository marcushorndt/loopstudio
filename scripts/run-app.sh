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
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
# A running copy would only be brought to the front, with the old code. Quit it first.
pkill -x LoopStudioApp 2>/dev/null && sleep 1
open "$app"

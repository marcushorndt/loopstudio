#!/bin/zsh
# Installs LoopStudio and its plugins from this disk image. Double-click it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
echo "LoopStudio installer"
echo

if [ "$(uname -m)" != "arm64" ]; then
  echo "This build runs on Apple Silicon only."; read -r; exit 1
fi

echo "1. The app goes to /Applications."
rm -rf /Applications/LoopStudio.app
ditto "$here/LoopStudio.app" /Applications/LoopStudio.app

comp="$HOME/Library/Audio/Plug-Ins/Components"
mkdir -p "$comp"
if [ -d "$here/Plug-Ins/Components" ]; then
  echo "2. The plugins go to $comp."
  for p in "$here"/Plug-Ins/Components/*.component; do
    name="$(basename "$p")"
    rm -rf "$comp/$name"
    ditto "$p" "$comp/$name"
    echo "   $name"
  done
fi

# The build is signed with a development certificate, not notarized. macOS marks files from a
# disk image as downloaded, so we remove that mark on what we installed. Nothing else changes.
echo "3. Removing the download mark."
xattr -dr com.apple.quarantine /Applications/LoopStudio.app 2>/dev/null
for p in "$comp"/*.component; do xattr -dr com.apple.quarantine "$p" 2>/dev/null; done
killall -9 AudioComponentRegistrar 2>/dev/null

roms="$HOME/Library/Application Support/Lemus/ROMs"
mkdir -p "$roms"
echo
echo "Done. The Lemus machines need their ROM dumps in:"
echo "   $roms"
echo "See READ-ME-FIRST.txt for the file names."
echo
echo "Press Return to close this window."
read -r

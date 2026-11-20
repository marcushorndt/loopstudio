#!/bin/zsh
# Pack the installed app and the installed plugins into a disk image for a private handover.
# Usage: scripts/pack-release.sh [--no-gaze] [--no-lemus] [--out DIR]
#
# The image holds LoopStudio.app (from /Applications), the plugins from
# ~/Library/Audio/Plug-Ins/Components that we know, Install.command, READ-ME-FIRST.txt and the
# licences. It never holds ROM dumps: the Lemus machines need them, the receiver supplies them.
# The result goes to the private handover folder ../3rd-party/loopstudio-private when it exists
# (next to the ROMs, where every earlier image lies), else to ~/Desktop; --out overrides.
set -euo pipefail
cd "$(dirname "$0")/.."
with_gaze=1; with_lemus=1
out="$HOME/Desktop"
[ -d "../3rd-party/loopstudio-private" ] && out="$(cd ../3rd-party/loopstudio-private && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-gaze) with_gaze=0;;
    --no-lemus) with_lemus=0;;
    --out) out="$2"; shift;;
    *) echo "unknown option $1"; exit 2;;
  esac
  shift
done

app="/Applications/LoopStudio.app"
[ -d "$app" ] || { echo "no $app: run scripts/install-app.sh first"; exit 1; }
version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.1)"
build="$(defaults read "$app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
comp="$HOME/Library/Audio/Plug-Ins/Components"
stage="$(mktemp -d "${TMPDIR:-/tmp}/loopstudio-pack.XXXXXX")"
vol="$stage/LoopStudio"
mkdir -p "$vol/Plug-Ins/Components" "$vol/Licenses"

ditto "$app" "$vol/LoopStudio.app"
cp scripts/release/Install.command "$vol/Install.command"
chmod +x "$vol/Install.command"
cp scripts/release/READ-ME-FIRST.txt "$vol/READ-ME-FIRST.txt"
cp LICENSE "$vol/Licenses/LoopStudio-GPL-3.0.txt"
[ -f Sources/LinkBridge/link/LICENSE.md ] && cp Sources/LinkBridge/link/LICENSE.md "$vol/Licenses/Ableton-Link-LICENSE.md"
[ -f Sources/RubberBandBridge/rubberband/COPYING ] && cp Sources/RubberBandBridge/rubberband/COPYING "$vol/Licenses/RubberBand-GPL-2.0.txt"

plugins=(remote-midi)
[ $with_gaze = 1 ] && plugins+=(Gaze)
if [ $with_lemus = 1 ]; then
  plugins+=(ro-mono-303 ro-mono-101 ro-drums-808 ro-drums-909 ac-digital-vc al-fx-quadgt)
  [ -f "../3rd-party/lemus/LICENSE" ] && cp "../3rd-party/lemus/LICENSE" "$vol/Licenses/Lemus-AGPL-3.0.txt"
fi
if [ $with_gaze = 1 ]; then
  for f in ../gaze/dsp/clouds/LICENSE ../gaze/dsp/cloudseed/LICENSE; do
    [ -f "$f" ] && cp "$f" "$vol/Licenses/Gaze-$(basename "$(dirname "$f")")-LICENSE.txt"
  done
fi
packed=()
for p in "${plugins[@]}"; do
  if [ -d "$comp/$p.component" ]; then
    ditto "$comp/$p.component" "$vol/Plug-Ins/Components/$p.component"
    packed+=("$p")
  else
    echo "skip $p: not installed in $comp"
  fi
done
# a safety net: no ROM dump may ride along
if find "$vol" \( -iname '*.zip' -o -iname '*.bin' -o -iname '*rom*.img' \) | grep -q .; then echo "ROM-like files in the image, stopping"; exit 1; fi

mkdir -p "$out"
dmg="$out/LoopStudio-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "LoopStudio $version" -srcfolder "$vol" -ov -format UDZO "$dmg"
rm -rf "$stage"
echo "packed $dmg (version $version, build $build)"
echo "plugins: ${packed[*]}"
shasum -a 256 "$dmg"

#!/usr/bin/env bash
# Copies SherpaEngine.xcframework (native/llama/build_ios.sh output) into the
# plugin, where ios/sherpa_inference/Package.swift and the podspec find it.
# Run on macOS after build_ios.sh, before `flutter build ios`:
#
#   native/llama/build_ios.sh
#   packages/sherpa_inference/tool/link_ios_engine.sh [path/to/SherpaEngine.xcframework]
#
# A copy (not a symlink) because SwiftPM rejects binary targets outside the
# package root, and Flutter symlinks plugin packages into the build.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
src="${1:-${SHERPA_IOS_XCFRAMEWORK:-$repo/native/llama/out/ios/SherpaEngine.xcframework}}"
dst="$here/ios/sherpa_inference/Frameworks/SherpaEngine.xcframework"
if [[ ! -d "$src" ]]; then
  echo "error: $src not found; run native/llama/build_ios.sh first (macOS + Xcode)" >&2
  exit 1
fi
[[ -f "$src/Info.plist" ]] || { echo "error: $src is not an xcframework (no Info.plist)" >&2; exit 1; }
mkdir -p "$(dirname "$dst")"
rm -rf "$dst"
cp -R "$src" "$dst"
echo "linked $(du -sh "$dst" | cut -f1) $dst"

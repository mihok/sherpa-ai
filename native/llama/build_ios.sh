#!/usr/bin/env bash
# Build SherpaEngine.xcframework (iOS 17.0+): one dynamic framework per slice (ios-arm64 device,
# ios-arm64-simulator) containing libsherpa_engine + llama.cpp + ggml (CPU, Metal with the embedded shader
# library, BLAS/Accelerate) + llama-common, exporting only the se_* C ABI.
#
#   native/llama/build_ios.sh          # -> native/llama/out/ios/SherpaEngine.xcframework(.zip), manifest.json
#
# Why not upstream's build-xcframework.sh: its framework merges libllama/ggml/mtmd but not llama-common
# (Jinja chat templates, tool-call parsers, sampler, speculative), which the engine needs, and its minimum
# OS is 16.4 (R05 §5.2). This script follows the same recipe (static libs -> libtool -> clang++ -dynamiclib
# -force_load -> vtool build version -> dSYM + strip -> xcodebuild -create-xcframework,
# build-xcframework.sh:293-447) with our own target list and an exported-symbols list.
#
# Requires macOS with Xcode (xcrun, xcodebuild, libtool, vtool, dsymutil) and CMake >= 3.22. NOT runnable
# on Linux; it has not been executed in the Linux CI host that produced the Android build.
#
# Environment: LLAMA_CPP_SRC (else native/llama/fetch.sh), SHERPA_NATIVE_CACHE, SHERPA_BUILD_DIR,
# SHERPA_OUT_DIR, JOBS, SHERPA_MTMD=1 (multimodal), GGML_METAL_EMBED_LIBRARY (default ON),
# SHERPA_STRICT=1 (Xcode version mismatch is an error), SHERPA_CLEAN=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/llama.lock"

log()  { printf '[ios] %s\n' "$*" >&2; }
die()  { printf '[ios] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { if [ "${SHERPA_STRICT:-0}" = "1" ]; then die "$*"; else printf '[ios] WARNING: %s\n' "$*" >&2; fi; }

[ "$(uname -s)" = "Darwin" ] || die "build_ios.sh needs macOS + Xcode"
for t in cmake xcrun; do command -v "$t" >/dev/null 2>&1 || die "$t not found"; done
XCODE_VER="$(xcrun xcodebuild -version 2>/dev/null | head -n1 | awk '{print $2}')"
case "$XCODE_VER" in "$XCODE_VERSION"*) ;; *) warn "Xcode $XCODE_VER != pinned $XCODE_VERSION" ;; esac
MIN_OS="$IOS_DEPLOYMENT_TARGET"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"
EMBED="${GGML_METAL_EMBED_LIBRARY:-ON}"
MTMD=OFF; [ "${SHERPA_MTMD:-0}" = "1" ] && MTMD=ON
FW=SherpaEngine

eval "$("$HERE/fetch.sh" --no-kleidiai)"
export GIT_CEILING_DIRECTORIES="$(dirname "$LLAMA_CPP_SRC")${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"
CACHE_DIR="${SHERPA_NATIVE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sherpa-native}"
B="${SHERPA_BUILD_DIR:-$CACHE_DIR/build/ios}"
OUT="${SHERPA_OUT_DIR:-$HERE/out/ios}"
[ "${SHERPA_CLEAN:-0}" = "1" ] && rm -rf "$B"
mkdir -p "$B"
T_START=$(date +%s)

# -g: dSYMs are produced below; the file-prefix maps keep build paths out of DWARF and __FILE__.
CFLAGS_COMMON="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g \
-ffile-prefix-map=$LLAMA_CPP_SRC=llama.cpp -ffile-prefix-map=$REPO=sherpa"

# build_slice <name> <sysroot> <min-version flag> <CFBundleSupportedPlatforms value> <is_simulator>
build_slice() {
  local name="$1" sysroot="$2" min_flag="$3" platform_name="$4" is_sim="$5"
  local bdir="$B/$name" rdir="Release-$sysroot"
  log "configuring $name"
  cmake -S "$REPO/native/engine" -B "$bdir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$sysroot" \
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DCMAKE_C_FLAGS="$CFLAGS_COMMON" -DCMAKE_CXX_FLAGS="$CFLAGS_COMMON" \
    -DLLAMA_CPP_SRC="$LLAMA_CPP_SRC" \
    -DBUILD_SHARED_LIBS=OFF -DSHERPA_ENGINE_LIBRARY_TYPE=STATIC -DSHERPA_ENGINE_TESTS=OFF \
    -DSHERPA_ENGINE_MTMD="$MTMD" \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY="$EMBED" -DGGML_METAL_TARGET_OS=ios \
    -DGGML_BLAS_DEFAULT=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=OFF \
    > "$bdir.configure.log" 2>&1 || { tail -n 40 "$bdir.configure.log" >&2; die "configure $name failed"; }
  log "building $name"
  cmake --build "$bdir" --config Release --target sherpa_engine_bundle -j "$JOBS" -- -quiet \
    > "$bdir.build.log" 2>&1 || { grep -E "error" "$bdir.build.log" | head -n 40 >&2; die "build $name failed"; }

  local list="$bdir/sherpa-static-libs-Release.txt"
  [ -f "$list" ] || die "missing $list (CMake did not generate the archive list)"
  local libs=()
  while IFS= read -r l; do [ -n "$l" ] && { [ -f "$l" ] || die "archive $l missing"; libs+=("$l"); }; done < "$list"
  local all; all="$(printf '%s\n' "${libs[@]}")"
  for need in libsherpa_engine.a libllama.a libllama-common.a libggml-base.a libggml-cpu.a libggml-metal.a; do
    grep -q "/$need\$" <<< "$all" || die "$name: $need not in the bundle"  # no `| grep -q` under pipefail
  done

  # framework skeleton (flat iOS layout)
  local fdir="$bdir/framework/$FW.framework"
  rm -rf "$bdir/framework" "$bdir/dSYMs"; mkdir -p "$fdir/Headers" "$fdir/Modules" "$bdir/dSYMs" "$bdir/tmp"
  cp "$REPO/native/engine/include/sherpa_engine.h" "$fdir/Headers/"
  cat > "$fdir/Modules/module.modulemap" <<EOF
framework module $FW {
    umbrella header "sherpa_engine.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
EOF
  cat > "$fdir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$FW</string>
    <key>CFBundleIdentifier</key><string>io.github.mihok.sherpa.engine</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$FW</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>$MIN_OS</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>DTPlatformName</key><string>$sysroot</string>
    <key>DTSDKName</key><string>$sysroot$MIN_OS</string>
</dict>
</plist>
EOF

  # Merge the archives and link one dynamic framework binary that exports only _se_*.
  xcrun libtool -static -o "$bdir/tmp/combined.a" "${libs[@]}" 2>/dev/null
  local sdk_path; sdk_path="$(xcrun --sdk "$sysroot" --show-sdk-path)"
  xcrun -sdk "$sysroot" clang++ -dynamiclib -isysroot "$sdk_path" -arch arm64 "$min_flag" \
    -Wl,-force_load,"$bdir/tmp/combined.a" \
    -Wl,-exported_symbols_list,"$REPO/native/engine/src/sherpa_engine.exports" -Wl,-dead_strip \
    -framework Foundation -framework Metal -framework Accelerate -lc++ \
    -install_name "@rpath/$FW.framework/$FW" \
    -compatibility_version 1 -current_version 1.0.0 \
    -o "$fdir/$FW"
  if [ "$is_sim" = "false" ]; then
    # Mark the binary for the App Store's framework validation (build-xcframework.sh:382-411).
    xcrun vtool -set-build-version ios "$MIN_OS" "$MIN_OS" -replace -output "$fdir/$FW" "$fdir/$FW"
  fi
  xcrun dsymutil "$fdir/$FW" -o "$bdir/dSYMs/$FW.framework.dSYM"
  xcrun strip -x -S "$fdir/$FW" -o "$bdir/tmp/stripped"
  mv "$bdir/tmp/stripped" "$fdir/$FW"
  rm -rf "$fdir/$FW.dSYM" "$bdir/tmp"

  # Gates: exported symbols, deployment target, linked libraries.
  local extra
  extra="$(xcrun nm -gU "$fdir/$FW" | awk '{print $NF}' | grep -v '^_se_' || true)"
  [ -z "$extra" ] || die "$name exports non-se_ symbols: $(echo "$extra" | head -n5 | tr '\n' ' ')"
  local minos; minos="$(xcrun otool -l "$fdir/$FW" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$minos" = "$MIN_OS" ] || die "$name: LC_BUILD_VERSION minos is '$minos', want $MIN_OS"
  local bad
  bad="$(xcrun otool -L "$fdir/$FW" | tail -n +2 | awk '{print $1}' \
        | grep -v -E '^(/System/Library/Frameworks/(Foundation|Metal|Accelerate|CoreFoundation|MetalPerformanceShaders)\.framework/|/usr/lib/(libc\+\+|libSystem|libobjc)|@rpath/'"$FW"'\.framework/)' || true)"
  [ -z "$bad" ] || die "$name links unexpected libraries: $bad"
  log "$name: $(wc -c < "$fdir/$FW" | tr -d ' ') bytes, exports $(xcrun nm -gU "$fdir/$FW" | grep -c ' _se_')"
}

build_slice ios-arm64           iphoneos        "-mios-version-min=$MIN_OS"           iPhoneOS        false
build_slice ios-arm64-simulator iphonesimulator "-mios-simulator-version-min=$MIN_OS" iPhoneSimulator true

rm -rf "$OUT"; mkdir -p "$OUT"
xcrun xcodebuild -create-xcframework \
  -framework "$B/ios-arm64/framework/$FW.framework" -debug-symbols "$B/ios-arm64/dSYMs/$FW.framework.dSYM" \
  -framework "$B/ios-arm64-simulator/framework/$FW.framework" -debug-symbols "$B/ios-arm64-simulator/dSYMs/$FW.framework.dSYM" \
  -output "$OUT/$FW.xcframework"
( cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$FW.xcframework" "$FW.xcframework.zip" )
ZIP_SHA="$(shasum -a 256 "$OUT/$FW.xcframework.zip" | cut -d' ' -f1)"
SPM_SUM=""
command -v swift >/dev/null 2>&1 && SPM_SUM="$(cd "$OUT" && swift package compute-checksum "$FW.xcframework.zip" 2>/dev/null || true)"
T_END=$(date +%s)
cat > "$OUT/manifest.json" <<EOF
{
  "framework": "$FW",
  "slices": ["ios-arm64", "ios-arm64-simulator"],
  "ios_deployment_target": "$MIN_OS",
  "llama_commit": "$LLAMA_COMMIT",
  "llama_tree_sha256": "$LLAMA_TREE_SHA256",
  "xcode": "$XCODE_VER",
  "metal_embed_library": "$EMBED",
  "mtmd": "$MTMD",
  "zip_sha256": "$ZIP_SHA",
  "spm_checksum": "$SPM_SUM",
  "device_binary_bytes": $(wc -c < "$B/ios-arm64/framework/$FW.framework/$FW" | tr -d ' '),
  "simulator_binary_bytes": $(wc -c < "$B/ios-arm64-simulator/framework/$FW.framework/$FW" | tr -d ' '),
  "seconds": $((T_END - T_START))
}
EOF
log "output: $OUT/$FW.xcframework (zip sha256 $ZIP_SHA) in $((T_END - T_START)) s"
log "consume with SwiftPM .binaryTarget(name: \"$FW\", path: \"Frameworks/$FW.xcframework\") or a podspec vendored_frameworks"

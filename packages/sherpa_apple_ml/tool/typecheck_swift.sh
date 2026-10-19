#!/usr/bin/env bash
# Type-checks the plugin's Swift sources on Linux against hand-written
# stand-in modules (tool/swift_standins/), the way sherpa_platform's Swift was
# checked. There is no macOS/Xcode here, so this proves only that the code is
# consistent with the stand-ins' declarations — NOT with the real iOS SDK,
# Flutter.framework, mlx-swift(-lm) or FoundationModels. Linux also ignores
# `@available(iOS …)`, so availability gating is not checked.
#
# Usage: SWIFTC=/path/to/swiftc tool/typecheck_swift.sh [extra swiftc flags]
# (a Swift 6.x Linux toolchain from swift.org; 6.2.1 was used).
#
# Configurations:
#   spm      Flutter.framework + UIKit + MLX* + Tokenizers + FoundationModels
#            (the SwiftPM build: MLX and FM engines compiled)
#   cocoapods  no MLX modules (canImport(MLXLLM) is false: the podspec build)
#   old-sdk  no FoundationModels (an SDK before iOS 26)
set -euo pipefail

SWIFTC=${SWIFTC:-swiftc}
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/.." && pwd)
out="$here/.typecheck"
src="$pkg/ios/sherpa_apple_ml/Sources/sherpa_apple_ml"
rm -rf "$out"
mkdir -p "$out/base" "$out/mlx" "$out/fm" "$out/src"

module() { # dir name file [deps-dirs...]
  local dir=$1 name=$2 file=$3
  shift 3
  local includes=()
  for d in "$@"; do includes+=(-I "$d"); done
  "$SWIFTC" -parse-as-library -swift-version 5 -emit-module -module-name "$name" \
    -emit-module-path "$dir/$name.swiftmodule" "${includes[@]}" "$here/swift_standins/$file"
}

module "$out/base" Flutter Flutter.swift
module "$out/base" UIKit UIKit.swift
module "$out/base" Metal Metal.swift
module "$out/base" os os.swift
module "$out/mlx" MLX MLX.swift
module "$out/mlx" MLXLMCommon MLXLMCommon.swift "$out/mlx"
module "$out/mlx" MLXLLM MLXLLM.swift "$out/mlx"
module "$out/mlx" Tokenizers Tokenizers.swift
module "$out/fm" FoundationModels FoundationModels.swift

# Pigeon's output only compiles for iOS/macOS (`#error` otherwise).
for f in "$src"/*.swift; do
  sed -e 's/#if os(iOS)$/#if os(iOS) || os(Linux)/' "$f" >"$out/src/$(basename "$f")"
done

check() { # label include-dirs...
  local label=$1
  shift
  local includes=()
  for d in "$@"; do includes+=(-I "$d"); done
  echo "== $label"
  "$SWIFTC" -typecheck -swift-version 5 -module-name sherpa_apple_ml "${includes[@]}" "${EXTRA_FLAGS[@]}" \
    "$out/src/"*.swift
}

EXTRA_FLAGS=("$@")
check spm "$out/base" "$out/mlx" "$out/fm"
check cocoapods "$out/base" "$out/fm"
check old-sdk "$out/base" "$out/mlx"
echo "OK: all configurations type-check against the stand-ins."

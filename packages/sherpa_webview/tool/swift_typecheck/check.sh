#!/usr/bin/env bash
# Linux type-check of sherpa_webview's Swift sources against stand-in
# UIKit / Flutter / WebKit modules that mirror the iOS 17 SDK declarations
# the plugin uses (incl. @MainActor isolation; WebKit delegate methods are
# declared as requirements so a mistyped witness fails). This is NOT a real
# iOS compile: see README "Swift".
#
#   SWIFT_TOOLCHAIN=/path/to/swift-6.x-RELEASE-ubuntu24.04/usr \
#     packages/sherpa_webview/tool/swift_typecheck/check.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/../../ios/sherpa_webview/Sources/sherpa_webview"
T="${SWIFT_TOOLCHAIN:?set SWIFT_TOOLCHAIN to a Swift 6.x Linux toolchain usr/ dir}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/mods" "$work/src"
for m in UIKit Flutter WebKit; do
  "$T/bin/swiftc" -swift-version 5 -parse-as-library -emit-module -module-name "$m" \
    -emit-module-path "$work/mods/$m.swiftmodule" -I "$work/mods" "$here/stubs/$m.swift" || exit 1
done
cp "$src"/*.swift "$work/src/"
# Linux-only substitutions: the generated file #errors off Apple platforms,
# and corelibs Foundation marks the Darwin trust constant unavailable.
sed -i 's/^#if os(iOS)$/#if true \/\/ Linux type-check: os(iOS)/' "$work/src/Messages.g.swift"
sed -i 's/\bNSURLAuthenticationMethodServerTrust\b/LinuxShim_NSURLAuthenticationMethodServerTrust/' "$work"/src/*.swift
status=0
for mode in "-swift-version 5" "-swift-version 5 -strict-concurrency=complete" "-swift-version 6"; do
  echo "=== swiftc -typecheck $mode"
  # shellcheck disable=SC2086
  "$T/bin/swiftc" $mode -typecheck -module-name sherpa_webview -I "$work/mods" "$work"/src/*.swift 2>&1 \
    | grep -E "(error|warning):" | sed "s#^$work/##" | sort -u
  r=${PIPESTATUS[0]}
  echo "exit=$r"
  [ "$r" -ne 0 ] && status=1
done
exit $status

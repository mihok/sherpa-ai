#!/usr/bin/env bash
# Runs analysis and every package's tests the way CI does. Usage:
#   tools/test_all.sh            # everything
#   tools/test_all.sh --dart     # pure-Dart packages only (fast)
set -euo pipefail
cd "$(dirname "$0")/.."

only_dart=false
[[ "${1:-}" == "--dart" ]] && only_dart=true

dart_pkgs=()
flutter_pkgs=()
for pubspec in packages/*/pubspec.yaml app/pubspec.yaml; do
  dir=$(dirname "$pubspec")
  [[ -d "$dir/test" ]] || continue
  if grep -qE '^\s+sdk:\s*flutter' "$pubspec"; then
    flutter_pkgs+=("$dir")
  else
    dart_pkgs+=("$dir")
  fi
done

echo "== pub get"
flutter pub get --enforce-lockfile >/dev/null

echo "== analyze"
dart analyze --fatal-infos

for dir in "${dart_pkgs[@]}"; do
  echo "== dart test $dir"
  (cd "$dir" && dart test --reporter=compact)
done

if ! $only_dart; then
  for dir in "${flutter_pkgs[@]}"; do
    echo "== flutter test $dir"
    (cd "$dir" && flutter test --reporter=compact)
  done
fi
echo "== all green"

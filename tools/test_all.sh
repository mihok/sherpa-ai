#!/usr/bin/env bash
# Runs analysis and every package's tests the way CI does. Usage:
#   tools/test_all.sh            # everything
#   tools/test_all.sh --dart     # analyze + pure-Dart packages only (fast)
#   tools/test_all.sh --flutter  # Flutter packages and the app only
set -euo pipefail
cd "$(dirname "$0")/.."

mode=all
case "${1:-}" in
  --dart) mode=dart ;;
  --flutter) mode=flutter ;;
  "") ;;
  *) echo "usage: $0 [--dart|--flutter]" >&2; exit 2 ;;
esac

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

if [[ $mode != flutter ]]; then
  echo "== analyze"
  dart analyze --fatal-infos

  for dir in "${dart_pkgs[@]}"; do
    echo "== dart test $dir"
    (cd "$dir" && dart test --reporter=compact)
  done
fi

if [[ $mode != dart ]]; then
  for dir in "${flutter_pkgs[@]}"; do
    echo "== flutter test $dir"
    (cd "$dir" && flutter test --reporter=compact)
  done
fi
echo "== all green"

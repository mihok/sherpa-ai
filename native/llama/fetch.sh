#!/usr/bin/env bash
# Resolve the pinned llama.cpp (and KleidiAI) sources for Sherpa's native builds, verify them, and print
# shell assignments for the build scripts:
#
#   eval "$(native/llama/fetch.sh)"            # -> LLAMA_CPP_SRC=... KLEIDIAI_SRC=...
#   native/llama/fetch.sh --no-kleidiai        # iOS / host builds do not need KleidiAI
#   native/llama/fetch.sh --print-tree-hash <llama.cpp dir>      # when bumping the pin
#   native/llama/fetch.sh --print-tree-hash-kleidiai <dir>
#
# Resolution order (llama.cpp), per docs/research/05-llamacpp-build.md §7.2:
#   1. $LLAMA_CPP_SRC                         (used in place; verified)
#   2. $SHERPA_NATIVE_CACHE/llama.cpp-<commit>  (default cache: ${XDG_CACHE_HOME:-~/.cache}/sherpa-native)
#   3. GitHub archive tarball of the pinned commit
#   4. PyPI sdist of llama-cpp-python that vendors exactly that commit (sha256-checked)
# KleidiAI: $KLEIDIAI_SRC, then cache, then gitlab.arm.com, then GitHub (sha256-checked).
#
# Every candidate tree is verified against the content hash in llama.lock (LLAMA_TREE_SHA256 /
# KLEIDIAI_TREE_SHA256). A mismatching override only warns unless SHERPA_STRICT=1. Sources are kept
# OUTSIDE the repo on purpose: ggml runs `git rev-parse` in its own directory (ggml/CMakeLists.txt:13-40),
# so a tree inside the Sherpa checkout would embed Sherpa's commit (and "-dirty") into the binaries.
#
# Environment: LLAMA_CPP_SRC, KLEIDIAI_SRC, SHERPA_NATIVE_CACHE, SHERPA_STRICT=1, SHERPA_OFFLINE=1
# (never download), CURL_OPTS (extra curl flags).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/llama.lock"

log()  { printf '[fetch] %s\n' "$*" >&2; }
die()  { printf '[fetch] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[fetch] WARNING: %s\n' "$*" >&2; }

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
sha256_file() { sha256_cmd "$1" | cut -d' ' -f1; }

# Content hash: sorted "sha256  relative/path" lines over the build-relevant paths, hashed again.
# Must stay byte-identical to the command used to produce LLAMA_TREE_SHA256 in llama.lock.
llama_tree_hash() {
  local dir="$1"
  ( cd "$dir" &&
    find CMakeLists.txt LICENSE cmake common ggml include src vendor tools/mtmd licenses \
         -type f ! -name '.git' ! -path '*/.git/*' -print0 2>/dev/null |
    LC_ALL=C sort -z | xargs -0 sha256_cmd_wrapper | sha256_cmd | cut -d' ' -f1 )
}
kleidiai_tree_hash() {
  local dir="$1"
  ( cd "$dir" &&
    find . -type f ! -path './.git/*' -print0 |
    LC_ALL=C sort -z | xargs -0 sha256_cmd_wrapper | sha256_cmd | cut -d' ' -f1 )
}
# xargs cannot call shell functions; a tiny wrapper script keeps the hash command portable (Linux/macOS).
WRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sherpa-fetch.XXXXXX")"
trap 'rm -rf "$WRAP_DIR"' EXIT
cat > "$WRAP_DIR/sha256_cmd_wrapper" <<'EOF'
#!/bin/sh
if command -v sha256sum >/dev/null 2>&1; then exec sha256sum "$@"; else exec shasum -a 256 "$@"; fi
EOF
chmod +x "$WRAP_DIR/sha256_cmd_wrapper"
export PATH="$WRAP_DIR:$PATH"

download() { # url dest
  local url="$1" dest="$2"
  if [ "${SHERPA_OFFLINE:-0}" = "1" ]; then return 1; fi
  log "downloading $url"
  # Large archives through corporate/agent proxies get cut mid-stream (seen: HTTP/2 INTERNAL_ERROR on the
  # 76 MB sdist), so retry every error and resume the partial file. A 4xx (e.g. a 403 policy denial of
  # github.com) is final: --fail makes curl exit 22 and --retry-all-errors would only waste time on it, so
  # the loop below treats rc 22 as final.
  local attempt rc=1
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086
    curl --fail --location --silent --show-error --connect-timeout 20 -C - ${CURL_OPTS:-} -o "$dest" "$url" && return 0
    rc=$?
    case "$rc" in
      22) return 1 ;;            # HTTP >= 400: not transient
      33) rm -f "$dest" ;;       # server refused the range request: restart from scratch
    esac
    log "download attempt $attempt failed (curl rc=$rc), retrying"
    sleep 2
  done
  return "$rc"
}

ensure_outside_repo() { # dir
  local d="$1" top head
  if top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"; then
    head="$(git -C "$d" rev-parse HEAD 2>/dev/null || true)"
    if [ "$(cd "$top" && pwd -P)" = "$(cd "$d" && pwd -P)" ] && [ "$head" = "$LLAMA_COMMIT" ]; then
      return 0 # a real checkout of the pinned commit: ggml's git probe will report the right commit
    fi
    warn "$d is inside the git work tree $top (HEAD ${head:-?}); ggml would embed that repo's commit." \
         "Build scripts set GIT_CEILING_DIRECTORIES and pass LLAMA_BUILD_COMMIT explicitly."
  fi
}

verify_llama() { # dir -> 0 if hash matches
  local got
  got="$(llama_tree_hash "$1" || true)"
  if [ "$got" = "$LLAMA_TREE_SHA256" ]; then return 0; fi
  warn "llama.cpp tree hash mismatch in $1: got ${got:-<none>}, want $LLAMA_TREE_SHA256"
  return 1
}
verify_kleidiai() {
  local got
  got="$(kleidiai_tree_hash "$1" || true)"
  if [ "$got" = "$KLEIDIAI_TREE_SHA256" ]; then return 0; fi
  warn "KleidiAI tree hash mismatch in $1: got ${got:-<none>}, want $KLEIDIAI_TREE_SHA256"
  return 1
}

write_stamp() { # dir origin tree_hash
  printf 'commit=%s\ntree_sha256=%s\norigin=%s\nfetched=%s\n' "$LLAMA_COMMIT" "$3" "$2" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/.sherpa-source"
}

resolve_llama() {
  if [ -n "${LLAMA_CPP_SRC:-}" ]; then
    [ -f "$LLAMA_CPP_SRC/include/llama.h" ] || die "LLAMA_CPP_SRC=$LLAMA_CPP_SRC is not a llama.cpp tree"
    if ! verify_llama "$LLAMA_CPP_SRC"; then
      [ "${SHERPA_STRICT:-0}" = "1" ] && die "LLAMA_CPP_SRC does not match the pinned commit $LLAMA_COMMIT"
      warn "continuing with an unverified LLAMA_CPP_SRC (set SHERPA_STRICT=1 to fail)"
    fi
    ensure_outside_repo "$LLAMA_CPP_SRC"
    echo "$LLAMA_CPP_SRC"; return
  fi

  local cache="${SHERPA_NATIVE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sherpa-native}"
  local dest="$cache/llama.cpp-$LLAMA_COMMIT"
  mkdir -p "$cache"
  if [ -d "$dest" ]; then
    if verify_llama "$dest"; then echo "$dest"; return; fi
    warn "discarding corrupt cache entry $dest"; rm -rf "$dest"
  fi

  local tmp; tmp="$(mktemp -d "$cache/.tmp-llama.XXXXXX")"
  # 3. GitHub tarball
  if download "$LLAMA_GITHUB_TARBALL_URL" "$tmp/gh.tar.gz"; then
    local got; got="$(sha256_file "$tmp/gh.tar.gz")"
    if [ -n "$LLAMA_GITHUB_TARBALL_SHA256" ] && [ "$got" != "$LLAMA_GITHUB_TARBALL_SHA256" ]; then
      warn "GitHub tarball sha256 $got != pinned $LLAMA_GITHUB_TARBALL_SHA256 (falling back to tree hash)"
    fi
    [ -z "$LLAMA_GITHUB_TARBALL_SHA256" ] && log "GitHub tarball sha256=$got (record as LLAMA_GITHUB_TARBALL_SHA256)"
    mkdir -p "$tmp/gh" && tar -xzf "$tmp/gh.tar.gz" -C "$tmp/gh"
    if [ -d "$tmp/gh/llama.cpp-$LLAMA_COMMIT" ] && verify_llama "$tmp/gh/llama.cpp-$LLAMA_COMMIT"; then
      mv "$tmp/gh/llama.cpp-$LLAMA_COMMIT" "$dest"
      write_stamp "$dest" "$LLAMA_GITHUB_TARBALL_URL" "$LLAMA_TREE_SHA256"
      rm -rf "$tmp"; echo "$dest"; return
    fi
    warn "GitHub tarball did not verify"
  else
    log "GitHub tarball unavailable, trying the PyPI sdist mirror"
  fi
  # 4. PyPI sdist mirror
  if [ -n "$LLAMA_PYPI_SDIST_URL" ] && download "$LLAMA_PYPI_SDIST_URL" "$tmp/sdist.tar.gz"; then
    local got; got="$(sha256_file "$tmp/sdist.tar.gz")"
    [ "$got" = "$LLAMA_PYPI_SDIST_SHA256" ] || { rm -rf "$tmp"; die "PyPI sdist sha256 $got != $LLAMA_PYPI_SDIST_SHA256"; }
    mkdir -p "$tmp/py" && tar -xzf "$tmp/sdist.tar.gz" -C "$tmp/py" "$LLAMA_PYPI_SDIST_SUBDIR"
    # The sdist carries vendor/llama.cpp/.git as a dangling submodule gitlink; drop it so git commands in
    # ggml's CMake fail cleanly instead of pointing at a missing gitdir.
    rm -f "$tmp/py/$LLAMA_PYPI_SDIST_SUBDIR/.git"
    verify_llama "$tmp/py/$LLAMA_PYPI_SDIST_SUBDIR" || { rm -rf "$tmp"; die "PyPI sdist tree does not match $LLAMA_COMMIT"; }
    mv "$tmp/py/$LLAMA_PYPI_SDIST_SUBDIR" "$dest"
    write_stamp "$dest" "$LLAMA_PYPI_SDIST_URL" "$LLAMA_TREE_SHA256"
    rm -rf "$tmp"; echo "$dest"; return
  fi
  rm -rf "$tmp"
  die "could not obtain llama.cpp $LLAMA_COMMIT (set LLAMA_CPP_SRC, or allow network access)"
}

resolve_kleidiai() {
  if [ -n "${KLEIDIAI_SRC:-}" ]; then
    [ -f "$KLEIDIAI_SRC/CMakeLists.txt" ] || die "KLEIDIAI_SRC=$KLEIDIAI_SRC is not a KleidiAI tree"
    if ! verify_kleidiai "$KLEIDIAI_SRC"; then
      [ "${SHERPA_STRICT:-0}" = "1" ] && die "KLEIDIAI_SRC does not match $KLEIDIAI_VERSION"
      warn "continuing with an unverified KLEIDIAI_SRC"
    fi
    echo "$KLEIDIAI_SRC"; return
  fi
  local cache="${SHERPA_NATIVE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sherpa-native}"
  local dest="$cache/kleidiai-$KLEIDIAI_VERSION"
  mkdir -p "$cache"
  if [ -d "$dest" ]; then
    if verify_kleidiai "$dest"; then echo "$dest"; return; fi
    warn "discarding corrupt cache entry $dest"; rm -rf "$dest"
  fi
  local tmp; tmp="$(mktemp -d "$cache/.tmp-kai.XXXXXX")"
  local url
  for url in "$KLEIDIAI_URL" "$KLEIDIAI_URL_FALLBACK"; do
    if download "$url" "$tmp/kai.tar.gz"; then
      local got; got="$(sha256_file "$tmp/kai.tar.gz")"
      if [ "$got" != "$KLEIDIAI_SHA256" ]; then warn "KleidiAI archive from $url: sha256 $got != $KLEIDIAI_SHA256"; continue; fi
      mkdir -p "$tmp/x" && tar -xzf "$tmp/kai.tar.gz" -C "$tmp/x"
      local top; top="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -n1)"
      if [ -n "$top" ] && verify_kleidiai "$top"; then
        mv "$top" "$dest"; rm -rf "$tmp"; echo "$dest"; return
      fi
    fi
  done
  rm -rf "$tmp"
  die "could not obtain KleidiAI $KLEIDIAI_VERSION (set KLEIDIAI_SRC, or allow network access)"
}

WANT_KLEIDIAI=1
case "${1:-}" in
  --print-tree-hash)          llama_tree_hash "${2:?dir}"; exit 0 ;;
  --print-tree-hash-kleidiai) kleidiai_tree_hash "${2:?dir}"; exit 0 ;;
  --no-kleidiai)              WANT_KLEIDIAI=0 ;;
  -h|--help)                  sed -n '2,25p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

SRC="$(resolve_llama)"
printf 'LLAMA_CPP_SRC=%q\n' "$SRC"
printf 'LLAMA_COMMIT=%q\n' "$LLAMA_COMMIT"
if [ "$WANT_KLEIDIAI" = "1" ]; then
  KAI="$(resolve_kleidiai)"
  printf 'KLEIDIAI_SRC=%q\n' "$KAI"
fi

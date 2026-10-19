#!/usr/bin/env bash
# Build Sherpa's Android native payload (arm64-v8a): llama.cpp (libllama, libggml, libggml-base, every
# libggml-cpu-android_* variant) + libsherpa_engine.so + libc++_shared.so, then run the CI gates.
#
#   native/llama/build_android.sh            # -> native/llama/out/android/{jniLibs/arm64-v8a/*.so, ...}
#
# Flag set: docs/research/05-llamacpp-build.md §7.3 / §8:
#   GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS (runtime CPU dispatch over 7 Android variants; loaded by
#   sherpa_engine's bare-name best-first loader, §4.3), KleidiAI (offline via FETCHCONTENT_SOURCE_DIR,
#   §4.4), ANDROID_STL=c++_shared (several .so files share one libc++, §4.8), GGML_OPENMP=OFF (libomp.so is
#   not a platform library, §4.5), GGML_LLAMAFILE=OFF, GGML_LTO=ON (§4.9), all LLAMA_BUILD_* off except
#   the common library the engine needs.
#
# Outputs (OUT=${SHERPA_OUT_DIR:-native/llama/out/android}):
#   jniLibs/arm64-v8a/*.so          --strip-debug copies (symbol table kept for Play's SYMBOL_TABLE level;
#                                   AGP strips further when packaging)
#   symbols-arm64-v8a.tar.gz        unstripped libraries + build-ids.txt (for ndk-stack / crash symbolication)
#   variants.txt                    CPU variants in the build (the engine's loader list comes from the build)
#   manifest.json                   pins, flags, per-file sizes + sha256 + build-id, gate results, timing
#
# Gates (fail the script): every PT_LOAD aligned to 0x4000 (16 KB pages, Play requirement for targetSdk 35+
# from 2027-02-01, §4.7); NEEDED within an allow-list (no libomp.so / libOpenCL.so / anything unexpected);
# all 7 variants present and exporting ggml_backend_score/ggml_backend_init; libsherpa_engine.so exports
# only se_*; stripped (--strip-unneeded) payload <= ANDROID_SIZE_BUDGET_BYTES from llama.lock.
#
# Environment: ANDROID_NDK_HOME / ANDROID_NDK / ANDROID_HOME / ANDROID_SDK_ROOT, LLAMA_CPP_SRC, KLEIDIAI_SRC,
# SHERPA_NATIVE_CACHE, SHERPA_BUILD_DIR, SHERPA_OUT_DIR, JOBS (default 3), SHERPA_STRICT=1 (toolchain
# version mismatches are errors), SHERPA_MTMD=0 (leave out multimodal/vision support, which is built by
# default: libmtmd.so, ~1.8 MB stripped), SHERPA_CLEAN=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/llama.lock"

log()  { printf '[android] %s\n' "$*" >&2; }
die()  { printf '[android] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { if [ "${SHERPA_STRICT:-0}" = "1" ]; then die "$*"; else printf '[android] WARNING: %s\n' "$*" >&2; fi; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size_of() { wc -c < "$1" | tr -d ' '; }

T_START=$(date +%s)
ABI="${ANDROID_ABI:-arm64-v8a}"
[ "$ABI" = "arm64-v8a" ] || die "only arm64-v8a is supported (R05 §4.10: armeabi-v7a has no variant scoring)"
JOBS="${JOBS:-3}"

# ---- toolchain -------------------------------------------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-$SDK/ndk/$ANDROID_NDK_VERSION}}"
[ -f "$NDK/build/cmake/android.toolchain.cmake" ] || die "Android NDK not found at $NDK (set ANDROID_NDK_HOME)"
NDK_REV="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" | tr -d '[:space:]')"
[ "$NDK_REV" = "$ANDROID_NDK_VERSION" ] || warn "NDK $NDK_REV != pinned $ANDROID_NDK_VERSION"
CMAKE_BIN="$SDK/cmake/$ANDROID_CMAKE_VERSION/bin/cmake"
[ -x "$CMAKE_BIN" ] || { CMAKE_BIN="$(command -v cmake || true)"; warn "pinned CMake $ANDROID_CMAKE_VERSION not in the SDK; using ${CMAKE_BIN:-none}"; }
[ -n "$CMAKE_BIN" ] || die "cmake not found"
NINJA_BIN="$(dirname "$CMAKE_BIN")/ninja"
[ -x "$NINJA_BIN" ] || NINJA_BIN="$(command -v ninja || true)"
[ -n "$NINJA_BIN" ] || die "ninja not found"
case "$(uname -s)" in
  Linux)  HOST_TAG=linux-x86_64 ;;
  Darwin) HOST_TAG=darwin-x86_64 ;;
  *) die "unsupported build host $(uname -s)" ;;
esac
LLVM_BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
READELF="$LLVM_BIN/llvm-readelf"; STRIP="$LLVM_BIN/llvm-strip"; NM="$LLVM_BIN/llvm-nm"
LIBCXX="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
for t in "$READELF" "$STRIP" "$NM" "$LIBCXX"; do [ -e "$t" ] || die "missing NDK file $t"; done
log "NDK $NDK_REV, CMake $("$CMAKE_BIN" --version | head -n1 | awk '{print $3}'), ninja $("$NINJA_BIN" --version)"

# ---- sources (verified, outside the repo) ------------------------------------------------------------------
eval "$("$HERE/fetch.sh")"
[ -n "${LLAMA_CPP_SRC:-}" ] && [ -n "${KLEIDIAI_SRC:-}" ] || die "fetch.sh did not resolve the sources"
case "$LLAMA_CPP_SRC/" in "$REPO"/*) warn "LLAMA_CPP_SRC is inside the repository; ggml would embed Sherpa's git commit" ;; esac
# ggml runs `git rev-parse` in its own directory (ggml/CMakeLists.txt:13-40); never let it climb into an
# enclosing repository.
export GIT_CEILING_DIRECTORIES="$(dirname "$LLAMA_CPP_SRC")${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1759276800}"  # 2026-10-01 (the pinned commit); also forces GGML_NATIVE off

CACHE_DIR="${SHERPA_NATIVE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sherpa-native}"
B="${SHERPA_BUILD_DIR:-$CACHE_DIR/build/android-$ABI}"
OUT="${SHERPA_OUT_DIR:-$HERE/out/android}"
[ "${SHERPA_CLEAN:-0}" = "1" ] && rm -rf "$B"
mkdir -p "$B"
MTMD=ON; [ "${SHERPA_MTMD:-1}" = "0" ] && MTMD=OFF

# ---- configure + build ------------------------------------------------------------------------------------
T_CFG=$(date +%s)
# Stable paths in DWARF / __FILE__ (R05 §7.6). Passed via CFLAGS/CXXFLAGS because the NDK toolchain puts
# its own flags into CMAKE_<LANG>_FLAGS_INIT (build/cmake/flags.cmake), which -DCMAKE_C_FLAGS would drop.
PREFIX_MAPS="-ffile-prefix-map=$LLAMA_CPP_SRC=llama.cpp -ffile-prefix-map=$REPO=sherpa"
CFLAGS="$PREFIX_MAPS" CXXFLAGS="$PREFIX_MAPS" \
"$CMAKE_BIN" -S "$REPO/native/engine" -B "$B" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$ANDROID_PLATFORM" -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CPP_SRC="$LLAMA_CPP_SRC" \
  -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF \
  -DGGML_CPU_KLEIDIAI=ON -DFETCHCONTENT_SOURCE_DIR_KLEIDIAI="$KLEIDIAI_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF -DGGML_CCACHE=OFF -DGGML_LTO=ON \
  -DSHERPA_ENGINE_MTMD="$MTMD" -DSHERPA_ENGINE_TESTS=OFF \
  > "$B/configure.log" 2>&1 || { tail -n 40 "$B/configure.log" >&2; die "configure failed ($B/configure.log)"; }
T_BUILD=$(date +%s)
"$CMAKE_BIN" --build "$B" --target sherpa_engine -j"$JOBS" > "$B/build.log" 2>&1 \
  || { grep -E "error|FAILED" "$B/build.log" | head -n 40 >&2; die "build failed ($B/build.log)"; }
T_DONE=$(date +%s)
log "configure $((T_BUILD - T_CFG)) s, build $((T_DONE - T_BUILD)) s (-j$JOBS)"

# ---- collect ----------------------------------------------------------------------------------------------
STAGE="$B/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/unstripped" "$STAGE/debug" "$STAGE/unneeded"
ENGINE_SO="$(find "$B" -maxdepth 2 -name libsherpa_engine.so -type f | head -n1)"
[ -n "$ENGINE_SO" ] || die "libsherpa_engine.so not found in $B"
cp "$ENGINE_SO" "$STAGE/unstripped/"
for so in "$B"/bin/lib*.so; do cp "$so" "$STAGE/unstripped/"; done
cp "$LIBCXX" "$STAGE/unstripped/"
cp "$B/variants.txt" "$STAGE/variants.txt"

FAIL=0
gate_fail() { printf '[android] GATE FAILED: %s\n' "$*" >&2; FAIL=1; }

# Variants: the list the engine compiled in must match the files we ship.
EXPECTED_VARIANTS=7
NV=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  NV=$((NV + 1))
  f="$STAGE/unstripped/libggml-cpu-$v.so"
  [ -f "$f" ] || { gate_fail "variant $v listed in variants.txt but libggml-cpu-$v.so missing"; continue; }
  # Capture first, then match: `producer | grep -q` under `set -o pipefail` fails at random when grep
  # exits early and the producer dies of SIGPIPE.
  syms="$("$NM" -D --defined-only "$f" | awk '{print $NF}')"
  for sym in ggml_backend_score ggml_backend_init; do
    grep -qx "$sym" <<< "$syms" || gate_fail "libggml-cpu-$v.so does not export $sym"
  done
done < "$STAGE/variants.txt"
[ "$NV" -eq "$EXPECTED_VARIANTS" ] || gate_fail "expected $EXPECTED_VARIANTS Android CPU variants, build has $NV"

ALLOWED_NEEDED="libc.so libm.so libdl.so liblog.so libandroid.so libc++_shared.so libggml-base.so libggml.so libllama.so libmtmd.so"
TOTAL_DEBUG=0; TOTAL_UNNEEDED=0; TOTAL_RAW=0
FILES_JSON=""; BUILD_IDS=""
for f in "$STAGE"/unstripped/*.so; do
  name="$(basename "$f")"
  # 16 KB page alignment of every loadable segment.
  aligns="$("$READELF" -lW "$f" | awk '$1 == "LOAD" { print $NF }' | sort -u | tr '\n' ' ')"
  [ "$aligns" = "0x4000 " ] || gate_fail "$name LOAD alignment is '$aligns', want 0x4000"
  hdr="$("$READELF" -hW "$f")"
  case "$hdr" in *AArch64*) ;; *) gate_fail "$name is not an AArch64 ELF" ;; esac
  # NEEDED allow-list (catches libomp.so from GGML_OPENMP=ON, libOpenCL.so linked hard, ...).
  for n in $("$READELF" -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
    case " $ALLOWED_NEEDED " in *" $n "*) ;; *) gate_fail "$name needs $n (not in the allow-list)" ;; esac
  done
  cp "$f" "$STAGE/debug/$name"; "$STRIP" --strip-debug "$STAGE/debug/$name"
  cp "$f" "$STAGE/unneeded/$name"; "$STRIP" --strip-unneeded "$STAGE/unneeded/$name"
  raw=$(size_of "$f"); dbg=$(size_of "$STAGE/debug/$name"); unn=$(size_of "$STAGE/unneeded/$name")
  TOTAL_RAW=$((TOTAL_RAW + raw)); TOTAL_DEBUG=$((TOTAL_DEBUG + dbg)); TOTAL_UNNEEDED=$((TOTAL_UNNEEDED + unn))
  notes="$("$READELF" -nW "$f")"
  bid="$(awk '/Build ID:/ { print $NF; exit }' <<< "$notes")"
  BUILD_IDS="$BUILD_IDS$bid  $name"$'\n'
  FILES_JSON="$FILES_JSON${FILES_JSON:+,}
    {\"name\": \"$name\", \"bytes_unstripped\": $raw, \"bytes_strip_debug\": $dbg, \"bytes_strip_unneeded\": $unn, \"build_id\": \"$bid\", \"sha256_strip_debug\": \"$(sha256_of "$STAGE/debug/$name")\"}"
done

# The engine exports exactly its C ABI (version script); anything else is an accidental C++ ABI.
EXTRA="$("$NM" -D --defined-only "$STAGE/unstripped/libsherpa_engine.so" | awk '{print $NF}' | grep -v '^se_' || true)"
[ -z "$EXTRA" ] || gate_fail "libsherpa_engine.so exports non-se_ symbols: $(echo "$EXTRA" | head -n5 | tr '\n' ' ')"
N_SE="$("$NM" -D --defined-only "$STAGE/unstripped/libsherpa_engine.so" | awk '{print $NF}' | grep -c '^se_' || true)"

[ "$TOTAL_UNNEEDED" -le "$ANDROID_SIZE_BUDGET_BYTES" ] \
  || gate_fail "stripped payload $TOTAL_UNNEEDED B exceeds the budget $ANDROID_SIZE_BUDGET_BYTES B"

# ---- publish --------------------------------------------------------------------------------------------
rm -rf "$OUT"; mkdir -p "$OUT/jniLibs/$ABI"
cp "$STAGE"/debug/*.so "$OUT/jniLibs/$ABI/"
cp "$STAGE/variants.txt" "$OUT/variants.txt"
printf '%s' "$BUILD_IDS" > "$STAGE/unstripped/build-ids.txt"
tar -czf "$OUT/symbols-$ABI.tar.gz" -C "$STAGE/unstripped" .
T_END=$(date +%s)
GATES=$([ "$FAIL" = "0" ] && echo pass || echo fail)
cat > "$OUT/manifest.json" <<EOF
{
  "abi": "$ABI",
  "llama_commit": "$LLAMA_COMMIT",
  "llama_tree_sha256": "$LLAMA_TREE_SHA256",
  "kleidiai": "$KLEIDIAI_VERSION",
  "ndk": "$NDK_REV",
  "cmake": "$("$CMAKE_BIN" --version | head -n1 | awk '{print $3}')",
  "android_platform": $ANDROID_PLATFORM,
  "stl": "c++_shared",
  "flags": "GGML_BACKEND_DL GGML_CPU_ALL_VARIANTS GGML_CPU_KLEIDIAI GGML_LTO; GGML_OPENMP=OFF GGML_LLAMAFILE=OFF GGML_NATIVE=OFF; SHERPA_ENGINE_MTMD=$MTMD",
  "cpu_variants": [$(sed 's/.*/"&"/' "$STAGE/variants.txt" | paste -sd, -)],
  "engine_exports": $N_SE,
  "bytes_strip_debug_total": $TOTAL_DEBUG,
  "bytes_strip_unneeded_total": $TOTAL_UNNEEDED,
  "bytes_unstripped_total": $TOTAL_RAW,
  "size_budget_bytes": $ANDROID_SIZE_BUDGET_BYTES,
  "gates": "$GATES",
  "seconds": {"configure": $((T_BUILD - T_CFG)), "build": $((T_DONE - T_BUILD)), "total": $((T_END - T_START))},
  "files": [$FILES_JSON
  ]
}
EOF

printf '\n%-40s %12s %12s %12s\n' "library" "unstripped" "strip-debug" "strip-unneed" >&2
for f in "$STAGE"/unstripped/*.so; do
  n="$(basename "$f")"
  printf '%-40s %12s %12s %12s\n' "$n" "$(size_of "$f")" "$(size_of "$STAGE/debug/$n")" "$(size_of "$STAGE/unneeded/$n")" >&2
done
printf '%-40s %12s %12s %12s\n' "TOTAL" "$TOTAL_RAW" "$TOTAL_DEBUG" "$TOTAL_UNNEEDED" >&2
log "variants: $(paste -sd' ' "$STAGE/variants.txt")"
log "engine exports $N_SE se_* symbols; budget $TOTAL_UNNEEDED / $ANDROID_SIZE_BUDGET_BYTES B"
log "output: $OUT ($((T_END - T_START)) s total)"
rm -rf "$STAGE/debug" "$STAGE/unneeded"
[ "$FAIL" = "0" ] || die "CI gates failed"
log "all gates passed"

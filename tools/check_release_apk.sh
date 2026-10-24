#!/usr/bin/env bash
# Release gate for a built Sherpa APK. CI runs it on every release APK (.github/workflows/ci.yml,
# job android-release); it works the same locally:
#
#   tools/check_release_apk.sh                                   # app/build/app/outputs/flutter-apk/app-release.apk
#   tools/check_release_apk.sh path/to/app.apk
#   tools/check_release_apk.sh --require-release-key --expect-cert <sha256> path/to/app.apk
#
# Checks (any failure exits 1, after all checks ran):
#   signature     apksigner verify; prints the signer DN and certificate SHA-256. A debug-key signature is a
#                 warning, or a failure with --require-release-key. --expect-cert pins the certificate.
#   alignment     zipalign -c -P 16 -v 4 (16 KB pages for uncompressed native libraries).
#   debuggable    neither `aapt2 dump badging` nor the binary manifest marks the app debuggable.
#   permissions   android.permission.INTERNET is requested.
#   service       io.github.mihok.sherpa_inference.InferenceService runs in the ":inference" process, is not
#                 exported, and its class is in the dex.
#   abis          lib/arm64-v8a is the only ABI directory. Plugins bring armeabi-v7a/x86_64 copies of their own
#                 libraries, and the engine is arm64-only: such an APK installs on a 32-bit-only or x86_64 device
#                 and fails there, at launch when the ABI has no libflutter.so (app/android/app/build.gradle.kts
#                 drops the other ABIs in release builds).
#   engine        lib/arm64-v8a holds the on-device engine (native/llama/build_android.sh) and the JNI shim;
#                 every native library is stored uncompressed (the engine dlopens CPU variants from the APK).
#   jni           every Java class named by a string in lib/arm64-v8a/*.so (io/, com/, org/, dev/ packages,
#                 bare or inside a type signature) exists in the dex or in the platform's android.jar; the
#                 lookups the shim does in JNI_OnLoad survive R8: EngineError.<init>(I[B)V,
#                 ProgressSink.onProgress(F)Z (and on every implementation), and NativeEngine's native
#                 methods match the shim's RegisterNatives table (from packages/sherpa_inference/android/
#                 src/main/cpp/sherpa_jni.c when it is available, and against the shim's strings always).
#
# Options:
#   --require-release-key       fail when the APK is signed with an Android debug certificate
#   --expect-cert SHA256        fail unless the signer certificate's SHA-256 matches (case and ':' ignored)
#   --summary FILE              append a Markdown report to FILE (e.g. "$GITHUB_STEP_SUMMARY")
#   --jni-source FILE           the shim source to read the RegisterNatives table from
#   --allow-missing-class NAME  a class (io/foo/Bar form) a native library may name without it being in the
#                               dex; repeatable
#
# Tools come from the Android SDK: ANDROID_HOME, ANDROID_SDK_ROOT, sdk.dir in app/android/local.properties,
# then the usual install locations; the newest build-tools with apksigner, zipalign, aapt2 and dexdump wins
# (override with BUILD_TOOLS=<dir>). Also needs java (apksigner), unzip and strings (binutils, or the NDK's
# llvm-strings).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PKG_INFERENCE=io/github/mihok/sherpa_inference
SERVICE_CLASS=io.github.mihok.sherpa_inference.InferenceService
NATIVE_ENGINE="$PKG_INFERENCE/engine/NativeEngine"
ENGINE_ERROR="$PKG_INFERENCE/engine/EngineError"
PROGRESS_SINK="$PKG_INFERENCE/engine/ProgressSink"
JNI_SHIM=libsherpa_inference_jni.so
ENGINE_LIBS="libsherpa_engine.so libllama.so libggml.so libggml-base.so libc++_shared.so"

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'check_release_apk: %s\n' "$*" >&2; exit 2; }

APK=""
REQUIRE_RELEASE_KEY=0
EXPECT_CERT=""
SUMMARY=""
JNI_SOURCE="$REPO/packages/sherpa_inference/android/src/main/cpp/sherpa_jni.c"
ALLOW_MISSING=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --require-release-key) REQUIRE_RELEASE_KEY=1 ;;
    --expect-cert) EXPECT_CERT="${2:?--expect-cert needs a value}"; shift ;;
    --summary) SUMMARY="${2:?--summary needs a file}"; shift ;;
    --jni-source) JNI_SOURCE="${2:?--jni-source needs a file}"; shift ;;
    --allow-missing-class) ALLOW_MISSING="$ALLOW_MISSING${2:?--allow-missing-class needs a name} "; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$APK" ] || die "only one APK per run"; APK="$1" ;;
  esac
  shift
done
APK="${APK:-$REPO/app/build/app/outputs/flutter-apk/app-release.apk}"
[ -f "$APK" ] || die "no APK at $APK (build it with: cd app && flutter build apk --release --target-platform android-arm64)"

# ---- tools ------------------------------------------------------------------------------------------------
sdk_dir() {
  local d
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
           "$(sed -n 's/^sdk\.dir=//p' "$REPO/app/android/local.properties" 2>/dev/null || true)" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/android-sdk /usr/local/lib/android/sdk; do
    [ -n "$d" ] && [ -d "$d/build-tools" ] && { printf '%s\n' "$d"; return; }
  done
  return 1
}
SDK="$(sdk_dir)" || die "Android SDK not found (set ANDROID_HOME)"
if [ -n "${BUILD_TOOLS:-}" ]; then
  BT="$BUILD_TOOLS"
else
  BT=""
  while IFS= read -r d; do
    if [ -x "$d/apksigner" ] && [ -x "$d/zipalign" ] && [ -x "$d/aapt2" ] && [ -x "$d/dexdump" ]; then BT="$d"; break; fi
  done < <(printf '%s\n' "$SDK"/build-tools/* | sort -V -r)
  [ -n "$BT" ] || die "no build-tools in $SDK/build-tools with apksigner, zipalign, aapt2 and dexdump"
fi
for t in apksigner zipalign aapt2 dexdump; do [ -x "$BT/$t" ] || die "missing $BT/$t"; done
command -v unzip > /dev/null || die "unzip not found"
STRINGS="$(command -v strings || command -v llvm-strings || true)"
if [ -z "$STRINGS" ]; then
  STRINGS="$(printf '%s\n' "$SDK"/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-strings | sort -V | tail -n1)"
fi
[ -x "$STRINGS" ] || die "strings not found (install binutils, or an NDK for llvm-strings)"
sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sherpa-apkcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- reporting --------------------------------------------------------------------------------------------
FAILED=0
ROWS=""
result() { # status check detail
  printf '%-4s  %-12s %s\n' "$1" "$2" "$3"
  ROWS="$ROWS| $1 | $2 | $(printf '%s' "$3" | sed 's/|/\\|/g') |"$'\n'
  [ "$1" != FAIL ] || FAILED=1
}
pass() { result PASS "$@"; }
warn() { result WARN "$@"; }
fail() { result FAIL "$@"; }
detail() { sed 's/^/        /'; }  # indented evidence under a result line

APK_SHA="$(sha256 "$APK")"
APK_BYTES="$(wc -c < "$APK" | tr -d ' ')"
BADGING="$("$BT/aapt2" dump badging "$APK" 2> /dev/null)" || die "aapt2 cannot read $APK"
MANIFEST="$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$APK" 2> /dev/null)" || die "aapt2 cannot dump the manifest"
PKG_LINE="$(grep -m1 '^package:' <<< "$BADGING")"
PACKAGE="$(sed -n "s/.* name='\([^']*\)'.*/\1/p" <<< "$PKG_LINE" | head -n1)"
VERSION_NAME="$(sed -n "s/.* versionName='\([^']*\)'.*/\1/p" <<< "$PKG_LINE")"
VERSION_CODE="$(sed -n "s/.* versionCode='\([^']*\)'.*/\1/p" <<< "$PKG_LINE")"
echo "APK      $APK"
echo "package  $PACKAGE $VERSION_NAME ($VERSION_CODE), $APK_BYTES bytes"
echo "sha256   $APK_SHA"
echo "tools    $BT"
echo

# ---- signature ------------------------------------------------------------------------------------------
CERT_SHA=""
CERT_DN=""
if SIG="$("$BT/apksigner" verify --verbose --print-certs "$APK" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"; then
  CERT_SHA="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<< "$SIG" | head -n1)"
  CERT_DN="$(sed -n 's/^Signer #1 certificate DN: //p' <<< "$SIG" | head -n1)"
  SCHEMES="$(sed -n 's/^Verified using \(v[0-9.]*\) scheme.*: true$/\1/p' <<< "$SIG" | paste -sd, -)"
  NSIGNERS="$(sed -n 's/^Number of signers: //p' <<< "$SIG")"
  if [ "${NSIGNERS:-1}" != 1 ]; then
    fail signature "$NSIGNERS signers (expected exactly one)"
  elif [[ "$CERT_DN" == *"CN=Android Debug"* ]]; then
    if [ "$REQUIRE_RELEASE_KEY" = 1 ]; then
      fail signature "signed with the Android debug key ($CERT_DN), but --require-release-key"
    else
      warn signature "debug key: $CERT_DN, cert SHA-256 $CERT_SHA (cannot update an install signed with the release key)"
    fi
  else
    pass signature "schemes ${SCHEMES:-?}; $CERT_DN; cert SHA-256 $CERT_SHA"
  fi
  if [ -n "$EXPECT_CERT" ]; then
    want="$(tr -d ':[:space:]' <<< "$EXPECT_CERT" | tr 'A-F' 'a-f')"
    if [ "$want" = "$CERT_SHA" ]; then pass cert-pin "certificate matches --expect-cert"
    else fail cert-pin "certificate $CERT_SHA != expected $want"; fi
  fi
else
  fail signature "apksigner verify failed"
  detail <<< "$SIG" | tail -n 15
fi

# ---- 16 KB zip alignment ---------------------------------------------------------------------------------
if ZA="$("$BT/zipalign" -c -P 16 -v 4 "$APK" 2>&1)"; then
  pass alignment "zipalign -c -P 16 -v 4: $(tail -n1 <<< "$ZA")"
else
  fail alignment "zipalign -c -P 16 -v 4 failed"
  grep -v '(OK' <<< "$ZA" | tail -n 15 | detail
fi

# ---- debuggable ------------------------------------------------------------------------------------------
DBG_BADGING="$(grep -c '^application-debuggable' <<< "$BADGING" || true)"
DBG_XML="$(grep -E ':debuggable\(0x0101000f\)=' <<< "$MANIFEST" | grep -vcE '=(false|0x0+|\(type 0x12\)0x0)$' || true)"
if [ "$DBG_BADGING" = 0 ] && [ "$DBG_XML" = 0 ]; then
  pass debuggable "not debuggable (badging and manifest)"
else
  fail debuggable "the app is debuggable (badging: $DBG_BADGING, manifest attribute: $DBG_XML)"
fi

# ---- permissions -----------------------------------------------------------------------------------------
if grep -qx "uses-permission: name='android.permission.INTERNET'" <<< "$BADGING"; then
  pass permissions "android.permission.INTERNET requested"
else
  fail permissions "android.permission.INTERNET missing: no remote providers, MCP servers or downloads"
fi

# ---- dex index -------------------------------------------------------------------------------------------
# One line per class (C desc), interface (I desc iface) and method (M desc name type FLAGS,...).
mkdir -p "$WORK/dex" "$WORK/so"
unzip -q -o "$APK" 'classes*.dex' -d "$WORK/dex" 2> /dev/null || true
DEX_FILES=("$WORK"/dex/classes*.dex)
[ -f "${DEX_FILES[0]}" ] || die "no classes*.dex in $APK"
"$BT/dexdump" -n "${DEX_FILES[@]}" 2> /dev/null | awk -v Q="'" '
  function q(s,   p) { split(s, p, Q); return p[2] }   # the text between the first pair of single quotes
  /^  Class descriptor/            { cls = q($0); sec = ""; print "C", cls; next }
  /^  Interfaces/                  { sec = "I"; next }
  /^  (Static|Instance) fields/    { sec = "F"; next }
  /^  (Direct|Virtual) methods/    { sec = "M"; next }
  /^  source_file_idx/             { sec = ""; next }
  sec == "I" && /^    #[0-9]+ +: / && index($0, Q) { print "I", cls, q($0); next }
  sec == "M" && /^      name +: /  { name = q($0); next }
  sec == "M" && /^      type +: /  { type = q($0); next }
  sec == "M" && /^      access +: / { a = $0; sub(/^[^(]*\(/, "", a); sub(/\).*$/, "", a); gsub(/ /, ",", a)
                                      print "M", cls, name, type, a; next }
' > "$WORK/dex.idx"
NCLASSES="$(grep -c '^C ' "$WORK/dex.idx" || true)"
[ "$NCLASSES" -gt 0 ] || die "dexdump produced no classes"
# Slash form (io/foo/Bar) of every class in the dex.
sed -n 's/^C L\(.*\);$/\1/p' "$WORK/dex.idx" | LC_ALL=C sort -u > "$WORK/dex.classes"
has_class() { LC_ALL=C grep -qxF "$1" "$WORK/dex.classes"; }
methods_of() { awk -v c="L$1;" '$1 == "M" && $2 == c { print $3, $4, $5 }' "$WORK/dex.idx"; }

# ---- :inference service ----------------------------------------------------------------------------------
SERVICES="$(awk '
  function v(s) { sub(/^[^=]*=/, "", s); sub(/ \(Raw: .*$/, "", s); gsub(/"/, "", s); return s }
  function flush() { if (inservice) print name "|" proc "|" exported; inservice = 0; name = proc = exported = "" }
  /^ *E: / { flush(); if ($2 == "service") inservice = 1; next }
  inservice && /:name\(0x01010003\)=/     { name = v($0) }
  inservice && /:process\(0x01010011\)=/  { proc = v($0) }
  inservice && /:exported\(0x01010010\)=/ { exported = v($0) }
  END { flush() }
' <<< "$MANIFEST")"
SVC="$(grep -F "$SERVICE_CLASS|" <<< "$SERVICES" | head -n1 || true)"
if [ -z "$SVC" ]; then
  fail service "$SERVICE_CLASS is not declared in the manifest"
else
  IFS='|' read -r _ svc_proc svc_exported <<< "$SVC"
  svc_class="$(tr . / <<< "$SERVICE_CLASS")"
  if [ "$svc_proc" != ":inference" ]; then
    fail service "$SERVICE_CLASS runs in process '${svc_proc:-<main>}', expected ':inference'"
  elif [ "$svc_exported" = "true" ]; then
    fail service "$SERVICE_CLASS is exported (other apps could bind the engine)"
  elif ! has_class "$svc_class"; then
    fail service "$SERVICE_CLASS is declared but its class is not in the dex"
  else
    pass service "$SERVICE_CLASS in \":inference\", exported=${svc_exported:-unset}, class present"
  fi
fi

# ---- native libraries ------------------------------------------------------------------------------------
LIB_ENTRIES="$(unzip -Z1 "$APK" 'lib/*' 2> /dev/null || true)"
OTHER_ABIS="$(awk -F/ 'NF > 2 && $2 != "arm64-v8a" { print $2 }' <<< "$LIB_ENTRIES" | LC_ALL=C sort -u)"
if [ -z "$OTHER_ABIS" ]; then
  pass abis "lib/arm64-v8a is the only ABI"
else
  fail abis "lib/ also holds $(paste -sd' ' - <<< "$OTHER_ABIS"): the APK would install on those devices and fail there (the engine is arm64-only; without libflutter.so it crashes at launch). Release builds exclude them in app/android/app/build.gradle.kts"
  while read -r abi; do
    files="$(awk -F/ -v a="$abi" '$2 == a && $3 != "" { print $3 }' <<< "$LIB_ENTRIES")"
    grep -qx libflutter.so <<< "$files" || files="$files"$'\n'"(no libflutter.so)"
    printf 'lib/%s: %s\n' "$abi" "$(paste -sd' ' - <<< "$files")"
  done <<< "$OTHER_ABIS" | detail
fi
LIBS="$(unzip -Z1 "$APK" 'lib/arm64-v8a/*.so' 2> /dev/null || true)"
missing=""
for l in $JNI_SHIM $ENGINE_LIBS; do grep -qx "lib/arm64-v8a/$l" <<< "$LIBS" || missing="$missing $l"; done
NVARIANTS="$(grep -c '^lib/arm64-v8a/libggml-cpu-android_.*\.so$' <<< "$LIBS" || true)"
if [ -n "$missing" ] || [ "$NVARIANTS" = 0 ]; then
  fail engine "lib/arm64-v8a lacks:${missing:- }$([ "$NVARIANTS" = 0 ] && echo ' libggml-cpu-android_*.so') (run native/llama/build_android.sh before flutter build)"
else
  pass engine "engine + JNI shim + $NVARIANTS CPU variants in lib/arm64-v8a ($(grep -c . <<< "$LIBS") libraries)"
fi
# zipinfo -l columns: mode, version, os, size, type, compressed size, method ("stor" = uncompressed), ...
COMPRESSED="$(unzip -Z -l "$APK" 'lib/*' 2> /dev/null | awk '$NF ~ /\.so$/ && $7 != "stor" { print $NF " (" $7 ")" }')"
if [ -z "$COMPRESSED" ]; then
  pass native-store "every native library is stored uncompressed"
else
  fail native-store "compressed native libraries (need extraction, break the engine's in-APK dlopen):"
  detail <<< "$COMPRESSED"
fi

# ---- JNI: classes named by native code -------------------------------------------------------------------
unzip -q -o "$APK" 'lib/arm64-v8a/*.so' -d "$WORK/so" 2> /dev/null || true
FRAMEWORK_JAR="$(printf '%s\n' "$SDK"/platforms/android-*/android.jar | sort -V | tail -n1)"
if [ -f "$FRAMEWORK_JAR" ]; then
  unzip -Z1 "$FRAMEWORK_JAR" '*.class' 2> /dev/null | sed 's/\.class$//' | LC_ALL=C sort -u > "$WORK/framework.classes"
else
  : > "$WORK/framework.classes"
fi
is_framework() {
  if [ -s "$WORK/framework.classes" ]; then LC_ALL=C grep -qxF "$1" "$WORK/framework.classes"; return; fi
  case "$1" in org/json/*|org/xmlpull/*|org/w3c/*|org/xml/*|org/apache/http/*|com/android/*) return 0 ;; esac
  return 1
}
CLASS_RE='^(io|com|org|dev)(/[A-Za-z0-9_$]+)+$'
: > "$WORK/refs"
for so in "$WORK"/so/lib/arm64-v8a/*.so; do
  [ -f "$so" ] || continue
  name="$(basename "$so")"
  "$STRINGS" -a -n 6 "$so" > "$WORK/strings.txt" 2> /dev/null || true
  {
    # Bare names (FindClass): a whole token, not the tail of a path or URL (".../java/com/foo").
    LC_ALL=C grep -oE '(^|[^A-Za-z0-9_$./-])(io|com|org|dev)/[A-Za-z0-9_$/.-]+' "$WORK/strings.txt" |
      sed -E 's#^[^iocd]##' | LC_ALL=C grep -E "$CLASS_RE" || true
    # Inside type signatures: Lio/foo/Bar;
    LC_ALL=C grep -oE 'L(io|com|org|dev)/[A-Za-z0-9_$/]+;' "$WORK/strings.txt" | sed -E 's#^L(.*);$#\1#' || true
  } | LC_ALL=C sort -u | sed "s#^#$name #" >> "$WORK/refs"
  # The shim's method names and signatures are short ("()I"): keep everything from 3 characters up.
  [ "$name" != "$JNI_SHIM" ] || "$STRINGS" -a -n 3 "$so" > "$WORK/shim.strings" 2> /dev/null || true
done
NREFS="$(grep -c . "$WORK/refs" || true)"
MISSING_REFS=""
while read -r lib cls; do
  [ -n "$cls" ] || continue
  has_class "$cls" && continue
  is_framework "$cls" && continue
  case "$ALLOW_MISSING" in *" $cls "*) continue ;; esac
  MISSING_REFS="$MISSING_REFS$lib -> $cls"$'\n'
done < "$WORK/refs"
if [ "$NREFS" = 0 ]; then
  fail jni-classes "no Java class names found in lib/arm64-v8a/*.so (string extraction broken?)"
elif [ -n "$MISSING_REFS" ]; then
  fail jni-classes "classes named by native code but missing from the dex (FindClass fails at runtime):"
  printf '%s' "$MISSING_REFS" | detail
else
  pass jni-classes "$NREFS class references from $(cut -d' ' -f1 "$WORK/refs" | sort -u | grep -c .) libraries, all in the dex"
fi
awk '{ printf "        %-28s %s\n", $1, $2 }' "$WORK/refs"

# ---- JNI: the shim's JNI_OnLoad lookups ------------------------------------------------------------------
# Captured before matching: `producer | grep -q` under pipefail fails at random when grep exits first.
ERROR_METHODS="$(methods_of "$ENGINE_ERROR")"
SINK_METHODS="$(methods_of "$PROGRESS_SINK")"
if grep -q '^<init> (I\[B)V ' <<< "$ERROR_METHODS"; then
  pass jni-error "EngineError.<init>(I[B)V present"
else
  fail jni-error "EngineError.<init>(I[B)V missing (R8 removed it? check consumer-rules.pro)"
fi
if grep -q '^onProgress (F)Z ' <<< "$SINK_METHODS"; then
  bad_impl=""
  nimpl=0
  while read -r impl; do
    nimpl=$((nimpl + 1))
    c="${impl#L}"; c="${c%;}"
    impl_methods="$(methods_of "$c")"
    grep -q '^onProgress (F)Z ' <<< "$impl_methods" || bad_impl="$bad_impl $c"
  done < <(awk -v i="L$PROGRESS_SINK;" '$1 == "I" && $3 == i { print $2 }' "$WORK/dex.idx")
  if [ -n "$bad_impl" ]; then
    fail jni-progress "ProgressSink implementations without onProgress(F)Z:$bad_impl"
  else
    pass jni-progress "ProgressSink.onProgress(F)Z present ($nimpl implementations keep it)"
  fi
else
  fail jni-progress "ProgressSink.onProgress(F)Z missing (R8 removed it? check consumer-rules.pro)"
fi

# ---- JNI: NativeEngine natives vs the shim's RegisterNatives table ---------------------------------------
methods_of "$NATIVE_ENGINE" | awk '$3 ~ /(^|,)NATIVE(,|$)/ { print $1, $2 }' | LC_ALL=C sort -u > "$WORK/natives.dex"
NNATIVE="$(grep -c . "$WORK/natives.dex" || true)"
if [ "$NNATIVE" = 0 ]; then
  fail jni-natives "NativeEngine has no native methods in the dex"
elif [ ! -f "$WORK/shim.strings" ]; then
  fail jni-natives "$JNI_SHIM is not in lib/arm64-v8a"
else
  problems=""
  # Binary check: the shim's strings name every native method and its signature (RegisterNatives
  # passes both as C strings) ...
  while read -r m s; do
    LC_ALL=C grep -qF -- "$m" "$WORK/shim.strings" || problems="$problems name $m not in the shim;"
    LC_ALL=C grep -qF -- "$s" "$WORK/shim.strings" || problems="$problems signature $m$s not in the shim;"
  done < "$WORK/natives.dex"
  # ... and every method signature the shim carries belongs to a method it can reach.
  awk '{ print $2 }' "$WORK/natives.dex" > "$WORK/known.sigs"
  printf '%s\n' '(I[B)V' '(F)Z' >> "$WORK/known.sigs"
  SIG_RE='^\((\[*([ZBCSIJFD]|L[A-Za-z0-9_$/]+;))*\)(V|\[*([ZBCSIJFD]|L[A-Za-z0-9_$/]+;))$'
  while read -r s; do
    LC_ALL=C grep -qxF -- "$s" "$WORK/known.sigs" || problems="$problems shim signature $s matches no dex method;"
  done < <(LC_ALL=C grep -E "$SIG_RE" "$WORK/shim.strings" | LC_ALL=C sort -u)
  # Source check: the exact {name, signature} table that RegisterNatives registers.
  table_note="shim source not found; binary check only"
  if [ -f "$JNI_SOURCE" ]; then
    awk '
      /^#define [A-Za-z_][A-Za-z0-9_]* "[^" ]*"[ \t]*$/ { v = $3; gsub(/"/, "", v); mac[$2] = v; next }
      /JNINativeMethod[ \t]+k_methods\[\][ \t]*=/ { t = 1; next }
      t && /^[ \t]*\};/ { exit }
      t && /^[ \t]*\{"/ {
        line = $0; sub(/^[ \t]*\{/, "", line); split(line, f, ",")
        name = f[1]; gsub(/[ \t"]/, "", name)
        n = split(f[2], tok, /[ \t]+/); sig = ""
        for (i = 1; i <= n; i++) {
          x = tok[i]; if (x == "") continue
          if (x ~ /^".*"$/) { gsub(/"/, "", x); sig = sig x }
          else if (x in mac) sig = sig mac[x]
          else { print "?", x; next }
        }
        print name, sig
      }' "$JNI_SOURCE" | LC_ALL=C sort -u > "$WORK/natives.src"
    NSRC="$(grep -c . "$WORK/natives.src" || true)"
    if [ "$NSRC" = 0 ] || grep -q '^? ' "$WORK/natives.src"; then
      problems="$problems could not parse k_methods in $JNI_SOURCE;"
    else
      table_note="RegisterNatives table in $(basename "$JNI_SOURCE"): $NSRC entries"
      while read -r m s; do problems="$problems registered $m$s is not a native method in the dex;"; done \
        < <(LC_ALL=C comm -23 "$WORK/natives.src" "$WORK/natives.dex")
      while read -r m s; do problems="$problems native $m$s is not registered by the shim;"; done \
        < <(LC_ALL=C comm -13 "$WORK/natives.src" "$WORK/natives.dex")
    fi
  fi
  if [ -z "$problems" ]; then
    pass jni-natives "NativeEngine: $NNATIVE native methods, all in $JNI_SHIM; $table_note"
  else
    fail jni-natives "NativeEngine natives do not match the shim ($table_note):"
    tr ';' '\n' <<< "$problems" | sed '/^ *$/d; s/^ //' | detail
  fi
fi

# ---- summary ---------------------------------------------------------------------------------------------
echo
if [ "$FAILED" = 0 ]; then echo "check_release_apk: all checks passed"; else echo "check_release_apk: FAILED"; fi
if [ -n "$SUMMARY" ]; then
  {
    echo "### Release APK checks: $([ "$FAILED" = 0 ] && echo passed || echo FAILED)"
    echo
    echo "\`$PACKAGE\` $VERSION_NAME ($VERSION_CODE), $APK_BYTES bytes"
    echo
    echo "- APK SHA-256: \`$APK_SHA\`"
    echo "- Signer: ${CERT_DN:-unknown}"
    echo "- Certificate SHA-256: \`${CERT_SHA:-unknown}\`"
    echo
    echo "| | Check | Result |"
    echo "|---|---|---|"
    printf '%s' "$ROWS"
    echo
  } >> "$SUMMARY"
fi
exit "$FAILED"

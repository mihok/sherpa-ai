#!/usr/bin/env bash
# Builds the :inference JNI shim (android/src/main/cpp) for the HOST (linux-x86_64 / macOS) so the Kotlin
# unit tests can System.load() it and drive the host engine (tool/build_host_engine.sh) for real:
#
#   tool/build_host_jni.sh                       # -> build/host-jni/libsherpa_inference_jni.so
#   cd <app>/android && ./gradlew :sherpa_inference:testDebugUnitTest
#
# The tests find it via SHERPA_JNI_LIB (default: this output), the engine via SHERPA_ENGINE_LIB (default:
# /opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so) and the model via SHERPA_TEST_MODEL;
# they skip cleanly when any is missing. Needs cmake, a C compiler and a JDK (JAVA_HOME or `java` on PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/build/host-jni}"
if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  export JAVA_HOME
fi
cmake -S "$here/android/src/main/cpp" -B "$out/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$out/cmake" >/dev/null
cp "$out/cmake/libsherpa_inference_jni."* "$out/" 2>/dev/null || true
ls -1 "$out"/libsherpa_inference_jni.*

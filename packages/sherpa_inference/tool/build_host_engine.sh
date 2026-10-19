#!/usr/bin/env bash
# Builds the shared host engine the Dart integration tests load
# (test/support/engine_env.dart reads SHERPA_ENGINE_LIB, defaulting to
# /opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so).
#
#   packages/sherpa_inference/tool/build_host_engine.sh [build-dir]
#   SHERPA_ENGINE_LIB=<build-dir>/libsherpa_engine.so flutter test   # in packages/sherpa_inference
#
# GGML_NATIVE stays OFF: a build tied to the build machine's CPU turned into
# SIGILL after a container migration here (native/llama/README.md).
# SHERPA_ENGINE_MTMD=ON builds the vision projector support (mmproj via
# llama.cpp's tools/mtmd), which the image-input integration tests use.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${1:-/opt/vendor-src/sherpa-engine-build/host-shared}"
eval "$("$repo/native/llama/fetch.sh" --no-kleidiai)"
cmake -S "$repo/native/engine" -B "$out" -G Ninja -DLLAMA_CPP_SRC="$LLAMA_CPP_SRC" \
  -DBUILD_SHARED_LIBS=ON -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_OPENMP=OFF \
  -DSHERPA_ENGINE_MTMD=ON -DSHERPA_ENGINE_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build "$out" -j"${JOBS:-3}" --target sherpa_engine
echo "SHERPA_ENGINE_LIB=$out/libsherpa_engine.so"

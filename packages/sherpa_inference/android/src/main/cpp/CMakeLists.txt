# JNI shim for the :inference service (sherpa_jni.c). It compiles against the engine HEADER only and dlopens
# libsherpa_engine.so at runtime, so it builds (and `flutter build apk` works) without the engine binaries.
#
# Two consumers:
#  - Android: the plugin's Gradle externalNativeBuild (android/build.gradle.kts), NDK, arm64-v8a/x86_64.
#  - Host JVM tests: tool/build_host_jni.sh configures this file with the host compiler and the JDK's jni.h
#    (find_package(JNI)), producing build/host-jni/libsherpa_inference_jni.so for the Kotlin unit tests.
cmake_minimum_required(VERSION 3.18)
project(sherpa_inference_jni C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The ABI header lives in the monorepo's native/engine (the single source of truth, also read by the
# hand-written Dart bindings). Override for out-of-tree builds.
set(SHERPA_ENGINE_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../native/engine/include"
    CACHE PATH "Directory containing sherpa_engine.h")
if(NOT EXISTS "${SHERPA_ENGINE_INCLUDE_DIR}/sherpa_engine.h")
  message(FATAL_ERROR "sherpa_engine.h not found in ${SHERPA_ENGINE_INCLUDE_DIR} (set SHERPA_ENGINE_INCLUDE_DIR)")
endif()

add_library(sherpa_inference_jni SHARED sherpa_jni.c)
target_include_directories(sherpa_inference_jni PRIVATE "${SHERPA_ENGINE_INCLUDE_DIR}")
target_compile_options(sherpa_inference_jni PRIVATE -Wall -Wextra -Werror=implicit-function-declaration
                       -fvisibility=hidden -O2)

if(ANDROID)
  target_link_libraries(sherpa_inference_jni PRIVATE dl)
  # 16 KB page alignment (Android 15+ devices with 16 KB pages, Play requirement); NDK r28+ defaults to it,
  # stated explicitly so the zipalign -P 16 gate never depends on the NDK default.
  target_link_options(sherpa_inference_jni PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--gc-sections")
else()
  # Only jni.h is needed (no libjvm link: the JVM loads us). JAVA_HOME avoids find_package(JNI)'s AWT probe,
  # which fails on headless JDKs.
  if(DEFINED ENV{JAVA_HOME} AND EXISTS "$ENV{JAVA_HOME}/include/jni.h")
    set(SHERPA_JNI_INCLUDES "$ENV{JAVA_HOME}/include" "$ENV{JAVA_HOME}/include/linux" "$ENV{JAVA_HOME}/include/darwin")
  else()
    find_package(JNI REQUIRED)
    set(SHERPA_JNI_INCLUDES ${JNI_INCLUDE_DIRS})
  endif()
  target_include_directories(sherpa_inference_jni PRIVATE ${SHERPA_JNI_INCLUDES})
  target_link_libraries(sherpa_inference_jni PRIVATE ${CMAKE_DL_LIBS} pthread)
endif()

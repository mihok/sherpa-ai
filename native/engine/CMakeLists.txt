# sherpa_engine: Sherpa's on-device inference engine. A small, versioned C ABI (include/sherpa_engine.h)
# over llama.cpp + common (Jinja chat templates, PEG tool-call parsers, lazy grammars, sampler,
# speculative decoding, sequence state). Plan of record: docs/PLAN.md "Local inference engine";
# API facts: docs/research/04-llamacpp-api.md; build facts: docs/research/05-llamacpp-build.md.
#
# Typical configurations (see native/llama/build_*.sh for the full flag sets):
#   host tests : -DLLAMA_CPP_SRC=<tree> -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=ON -DGGML_OPENMP=OFF
#                -DSHERPA_ENGINE_TESTS=ON
#   Android    : NDK toolchain, -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON ...
#   iOS        : -DBUILD_SHARED_LIBS=OFF -DSHERPA_ENGINE_LIBRARY_TYPE=STATIC (merged into a framework)
cmake_minimum_required(VERSION 3.22)
project(sherpa_engine VERSION 1.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SHERPA_ENGINE_TESTS "Build the host test suite (needs a GGUF model)" OFF)
option(SHERPA_ENGINE_MTMD  "Build multimodal (mmproj via tools/mtmd) support" OFF)
set(SHERPA_ENGINE_LIBRARY_TYPE "SHARED" CACHE STRING "SHARED (Android, host) or STATIC (iOS framework merge)")
set_property(CACHE SHERPA_ENGINE_LIBRARY_TYPE PROPERTY STRINGS SHARED STATIC)
set(LLAMA_CPP_SRC "$ENV{LLAMA_CPP_SRC}" CACHE PATH "Pinned llama.cpp source tree (native/llama/fetch.sh)")
set(SHERPA_TEST_MODEL "/opt/models/Qwen3-0.6B-Q4_K_M.gguf" CACHE FILEPATH "GGUF used by the host tests")
set(SHERPA_TEST_THREADS "4" CACHE STRING "Threads used by the host tests (lower it on shared CI runners)")
# Optional vision model + projector for the image-input test (needs SHERPA_ENGINE_MTMD), e.g. SmolVLM-256M:
# ggml-org/SmolVLM-256M-Instruct-GGUF SmolVLM-256M-Instruct-Q8_0.gguf + mmproj-SmolVLM-256M-Instruct-Q8_0.gguf.
set(SHERPA_TEST_VLM "" CACHE FILEPATH "Vision GGUF for the image-input test (empty: skipped)")
set(SHERPA_TEST_MMPROJ "" CACHE FILEPATH "Projector GGUF matching SHERPA_TEST_VLM")

# ---- pins ---------------------------------------------------------------------------------------------------
set(_sherpa_lock "${CMAKE_CURRENT_LIST_DIR}/../llama/llama.lock")
file(STRINGS "${_sherpa_lock}" _sherpa_pins REGEX "^(LLAMA_COMMIT|LLAMA_TREE_SHA256|LLAMA_VERSION)=")
foreach(_l IN LISTS _sherpa_pins)
  string(REGEX MATCH "^([A-Z0-9_]+)=(.*)$" _m "${_l}")
  set(SHERPA_PIN_${CMAKE_MATCH_1} "${CMAKE_MATCH_2}")
endforeach()
string(SUBSTRING "${SHERPA_PIN_LLAMA_COMMIT}" 0 7 _sherpa_commit7)

if(NOT EXISTS "${LLAMA_CPP_SRC}/include/llama.h")
  message(FATAL_ERROR "LLAMA_CPP_SRC='${LLAMA_CPP_SRC}' is not a llama.cpp tree. "
                      "Run: eval \"$(native/llama/fetch.sh --no-kleidiai)\" and pass -DLLAMA_CPP_SRC=$LLAMA_CPP_SRC")
endif()

# ---- llama.cpp: libraries only ---------------------------------------------------------------------------
# common/ is required (chat templates, tool-call parsers, sampler, speculative), so LLAMA_BUILD_COMMON is ON;
# everything else upstream builds by default is OFF. OpenSSL/subprocess are server-only features.
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
foreach(_o TESTS TOOLS EXAMPLES SERVER APP UI)
  set(LLAMA_BUILD_${_o} OFF CACHE BOOL "" FORCE)
endforeach()
set(LLAMA_OPENSSL    OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ${SHERPA_ENGINE_MTMD} CACHE BOOL "" FORCE)
set(MTMD_VIDEO       OFF CACHE BOOL "" FORCE)
# Record the pinned commit instead of whatever `git rev-parse` finds (R05 §7.6).
set(LLAMA_BUILD_COMMIT "${_sherpa_commit7}")
set(LLAMA_BUILD_NUMBER 0)
# Static llama/ggml (host, iOS) are linked into libsherpa_engine, so they must be PIC.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory("${LLAMA_CPP_SRC}" llama.cpp EXCLUDE_FROM_ALL)

find_package(Threads REQUIRED)

# ---- llama-common as a static archive -------------------------------------------------------------------
# With BUILD_SHARED_LIBS=ON (Android) upstream builds llama-common as its own .so that exports every C++
# symbol (no ABI promise, R04 §1) and cannot be dead-stripped. We compile the same sources into a static,
# PIC archive instead and link it into libsherpa_engine.so behind a version script, so only se_* is exported
# and --gc-sections drops the unused parts (arg parser, downloader, HTTP client).
function(sherpa_static_clone src dst)
  get_target_property(_srcs ${src} SOURCES)
  get_target_property(_dir  ${src} SOURCE_DIR)
  set(_abs "")
  foreach(_s IN LISTS _srcs)
    if(IS_ABSOLUTE "${_s}")
      list(APPEND _abs "${_s}")
    else()
      list(APPEND _abs "${_dir}/${_s}")
    endif()
  endforeach()
  add_library(${dst} STATIC ${_abs})
  foreach(_p INCLUDE_DIRECTORIES COMPILE_DEFINITIONS COMPILE_OPTIONS COMPILE_FEATURES
             INTERFACE_INCLUDE_DIRECTORIES INTERFACE_COMPILE_DEFINITIONS INTERFACE_COMPILE_FEATURES)
    get_target_property(_v ${src} ${_p})
    if(_v)
      set_property(TARGET ${dst} PROPERTY ${_p} "${_v}")
    endif()
  endforeach()
  # A static archive propagates all of its link dependencies (PUBLIC and PRIVATE) to the final link.
  get_target_property(_libs ${src} LINK_LIBRARIES)
  if(_libs)
    set_property(TARGET ${dst} PROPERTY LINK_LIBRARIES "${_libs}")
    set_property(TARGET ${dst} PROPERTY INTERFACE_LINK_LIBRARIES "${_libs}")
  endif()
  set_target_properties(${dst} PROPERTIES POSITION_INDEPENDENT_CODE ON)
  target_compile_options(${dst} PRIVATE $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-ffunction-sections -fdata-sections>)
endfunction()

get_target_property(_common_type llama-common TYPE)
if(_common_type STREQUAL "STATIC_LIBRARY")
  set(SHERPA_COMMON_TARGET llama-common)
else()
  sherpa_static_clone(llama-common sherpa_llama_common)
  set(SHERPA_COMMON_TARGET sherpa_llama_common)
endif()

# ---- build configuration header (CPU variants come from the build, not a hard-coded list; R05 §9) ---------
set(SE_CPU_VARIANTS "")
if(GGML_BACKEND_DL)
  get_target_property(_ggml_deps ggml MANUALLY_ADDED_DEPENDENCIES)
  foreach(_d IN LISTS _ggml_deps)
    if(_d MATCHES "^ggml-cpu-(.+)$")
      list(APPEND SE_CPU_VARIANTS "${CMAKE_MATCH_1}")
    endif()
  endforeach()
endif()
set(_variant_init "")
foreach(_v IN LISTS SE_CPU_VARIANTS)
  string(APPEND _variant_init "\"${_v}\", ")
endforeach()
list(LENGTH SE_CPU_VARIANTS SE_CPU_VARIANT_COUNT)
string(REPLACE ";" "\n" _variants_txt "${SE_CPU_VARIANTS}")
file(WRITE "${CMAKE_BINARY_DIR}/variants.txt" "${_variants_txt}\n")
if(GGML_BACKEND_DL)
  set(SE_BACKEND_DL 1)
else()
  set(SE_BACKEND_DL 0)
endif()
if(SHERPA_ENGINE_MTMD)
  set(SE_HAVE_MTMD 1)
else()
  set(SE_HAVE_MTMD 0)
endif()
configure_file("${CMAKE_CURRENT_LIST_DIR}/src/se_build_config.h.in"
               "${CMAKE_BINARY_DIR}/generated/se_build_config.h" @ONLY)

# ---- the engine -----------------------------------------------------------------------------------------
set(SE_SOURCES
  src/se_abi.cpp
  src/se_backend.cpp
  src/se_util.cpp
  src/se_model.cpp
  src/se_session.cpp
  src/se_generate.cpp
  src/se_media.cpp
  src/se_state.cpp
  src/se_bench.cpp
)
add_library(sherpa_engine ${SHERPA_ENGINE_LIBRARY_TYPE} ${SE_SOURCES})
target_include_directories(sherpa_engine
  PUBLIC  "${CMAKE_CURRENT_LIST_DIR}/include"
  PRIVATE "${CMAKE_CURRENT_LIST_DIR}/src" "${CMAKE_BINARY_DIR}/generated")
target_compile_definitions(sherpa_engine PRIVATE SE_BUILDING_LIBRARY)
target_link_libraries(sherpa_engine PRIVATE ${SHERPA_COMMON_TARGET} llama ggml vendor::hash
                                            Threads::Threads ${CMAKE_DL_LIBS})
if(SHERPA_ENGINE_MTMD)
  target_link_libraries(sherpa_engine PRIVATE mtmd)
endif()
if(ANDROID)
  target_link_libraries(sherpa_engine PRIVATE log)
endif()
set_target_properties(sherpa_engine PROPERTIES
  C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON
  OUTPUT_NAME sherpa_engine)
if(NOT MSVC)
  target_compile_options(sherpa_engine PRIVATE -Wall -Wextra -Wno-unused-parameter -ffunction-sections -fdata-sections)
endif()
if(SHERPA_ENGINE_LIBRARY_TYPE STREQUAL "SHARED")
  if(APPLE)
    target_link_options(sherpa_engine PRIVATE
      "-Wl,-exported_symbols_list,${CMAKE_CURRENT_LIST_DIR}/src/sherpa_engine.exports" "-Wl,-dead_strip")
  elseif(NOT MSVC)
    # Only se_* leaves the library; static archives (common, hash, and llama/ggml on the host) stay hidden.
    target_link_options(sherpa_engine PRIVATE
      "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/src/sherpa_engine.map"
      "-Wl,--exclude-libs,ALL" "-Wl,--gc-sections" "-Wl,--no-undefined"
      # NDK r28+ already defaults to 16 KB pages (R05 §4.7); keep it explicit for older toolchains.
      "$<$<BOOL:${ANDROID}>:-Wl,-z,max-page-size=16384>")
    set_property(TARGET sherpa_engine APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_LIST_DIR}/src/sherpa_engine.map")
  endif()
endif()

# ---- static bundle (iOS) --------------------------------------------------------------------------------
# build_ios.sh merges every static archive of the engine's link closure into one framework binary.
# Upstream's xcframework lacks llama-common (R05 §5.2), so we ship our own; CMake writes the exact archive
# paths for each configuration so the script never guesses generator-specific output directories.
if(SHERPA_ENGINE_LIBRARY_TYPE STREQUAL "STATIC")
  set(_bundle sherpa_engine)
  foreach(_t ${SHERPA_COMMON_TARGET} llama-common-base cpp-httplib vendor-hash llama ggml ggml-base ggml-cpu
             ggml-metal ggml-blas mtmd)
    if(TARGET ${_t})
      get_target_property(_ty ${_t} TYPE)
      if(_ty STREQUAL "STATIC_LIBRARY")
        list(APPEND _bundle ${_t})
      endif()
    endif()
  endforeach()
  set(_bundle_files "")
  foreach(_t IN LISTS _bundle)
    list(APPEND _bundle_files "$<TARGET_FILE:${_t}>")
  endforeach()
  file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/sherpa-static-libs-$<CONFIG>.txt"
       CONTENT "$<JOIN:${_bundle_files},\n>\n")
  add_custom_target(sherpa_engine_bundle DEPENDS ${_bundle})
endif()

# ---- host tests -----------------------------------------------------------------------------------------
if(SHERPA_ENGINE_TESTS)
  enable_testing()
  # The header must stay valid C (Dart ffigen, JNI, Swift import it as C).
  add_executable(sherpa_engine_c_abi_test tests/c_abi_test.c)
  target_link_libraries(sherpa_engine_c_abi_test PRIVATE sherpa_engine)
  add_test(NAME c_abi COMMAND sherpa_engine_c_abi_test)

  add_executable(sherpa_engine_tests tests/engine_tests.cpp)
  # nlohmann/json (header-only, vendored by llama.cpp) to inspect the engine's JSON in the tests.
  target_include_directories(sherpa_engine_tests PRIVATE "${LLAMA_CPP_SRC}/vendor")
  target_link_libraries(sherpa_engine_tests PRIVATE sherpa_engine Threads::Threads)

  # A small random LoRA adapter for the LoRA test, generated with llama.cpp's gguf-py (needs numpy).
  set(_lora "${CMAKE_BINARY_DIR}/testdata/test-lora.gguf")
  set(_vision_args "")
  if(SHERPA_TEST_VLM AND SHERPA_TEST_MMPROJ)
    set(_vision_args --vlm "${SHERPA_TEST_VLM}" --mmproj "${SHERPA_TEST_MMPROJ}")
  endif()
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    add_test(NAME make_test_lora
             COMMAND ${CMAKE_COMMAND} -E env --unset=PYTHONPATH ${Python3_EXECUTABLE} -I
                     "${CMAKE_CURRENT_LIST_DIR}/tests/make_test_lora.py" "${LLAMA_CPP_SRC}" "${SHERPA_TEST_MODEL}" "${_lora}")
    set_tests_properties(make_test_lora PROPERTIES FIXTURES_SETUP lora)
    add_test(NAME engine COMMAND sherpa_engine_tests --model "${SHERPA_TEST_MODEL}" --lora "${_lora}"
                                                     --threads ${SHERPA_TEST_THREADS} --tmp "${CMAKE_BINARY_DIR}"
                                                     --bench-json "${CMAKE_BINARY_DIR}/bench.json" ${_vision_args})
    set_tests_properties(engine PROPERTIES FIXTURES_REQUIRED lora)
  else()
    add_test(NAME engine COMMAND sherpa_engine_tests --model "${SHERPA_TEST_MODEL}" --threads ${SHERPA_TEST_THREADS}
                                                     --tmp "${CMAKE_BINARY_DIR}" --bench-json "${CMAKE_BINARY_DIR}/bench.json"
                                                     ${_vision_args})
  endif()
  set_tests_properties(engine PROPERTIES TIMEOUT 3600)
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/testdata")
endif()

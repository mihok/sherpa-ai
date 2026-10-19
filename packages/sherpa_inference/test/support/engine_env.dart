import 'dart:io';

/// Where the host-built shared engine lives when SHERPA_ENGINE_LIB is not
/// set (see the package README: "Host build for the Dart tests").
const String kDefaultHostEngine = '/opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so';
const String kDefaultTestModel = '/opt/models/Qwen3-0.6B-Q4_K_M.gguf';

/// The engine library for integration tests: `$SHERPA_ENGINE_LIB`, else the
/// default host build, else null.
String? engineLibraryPath() {
  final env = Platform.environment['SHERPA_ENGINE_LIB'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  return File(kDefaultHostEngine).existsSync() ? kDefaultHostEngine : null;
}

/// The GGUF for integration tests: `$SHERPA_TEST_MODEL`, else the default.
String? testModelPath() {
  final env = Platform.environment['SHERPA_TEST_MODEL'];
  final path = env == null || env.isEmpty ? kDefaultTestModel : env;
  return File(path).existsSync() ? path : null;
}

/// Null when the integration suite can run, else why it is skipped.
String? engineSkipReason() {
  if (engineLibraryPath() == null) {
    return 'no host engine library (set SHERPA_ENGINE_LIB or build $kDefaultHostEngine)';
  }
  if (testModelPath() == null) return 'no test model (set SHERPA_TEST_MODEL or provide $kDefaultTestModel)';
  return null;
}

/// Threads for engine tests: the host is shared, ggml's spinning barriers
/// degrade badly when another process takes a core (native/llama/README).
int get testThreads => int.tryParse(Platform.environment['SHERPA_TEST_THREADS'] ?? '') ?? 2;

/// A small vision model and its projector for the image-input tests:
/// `$SHERPA_TEST_VLM` / `$SHERPA_TEST_MMPROJ`, else SmolVLM-256M in
/// /opt/models/smolvlm-256m (ggml-org/SmolVLM-256M-Instruct-GGUF, Q8_0).
/// Null when either file is missing.
(String model, String mmproj)? visionModelPaths() {
  String pick(String env, String fallback) {
    final v = Platform.environment[env];
    return v == null || v.isEmpty ? fallback : v;
  }

  final model = pick('SHERPA_TEST_VLM', '/opt/models/smolvlm-256m/SmolVLM-256M-Instruct-Q8_0.gguf');
  final mmproj = pick('SHERPA_TEST_MMPROJ', '/opt/models/smolvlm-256m/mmproj-SmolVLM-256M-Instruct-Q8_0.gguf');
  return File(model).existsSync() && File(mmproj).existsSync() ? (model, mmproj) : null;
}

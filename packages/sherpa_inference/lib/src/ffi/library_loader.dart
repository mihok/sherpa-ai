import 'dart:ffi';
import 'dart:io';

import 'bindings.dart';

/// Environment variable naming an explicit engine library (host tests,
/// desktop development): an absolute path to `libsherpa_engine.so` /
/// `.dylib`.
const String kEngineLibraryEnv = 'SHERPA_ENGINE_LIB';

/// Why the engine cannot be used; surfaced as "engine unavailable".
final class EngineUnavailableException implements Exception {
  const EngineUnavailableException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'EngineUnavailableException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Where the engine library comes from on each platform.
///
/// * Android: `libsherpa_engine.so` by bare name. AGP packages the plugin's
///   jniLibs (native/llama/out/android/jniLibs) into the APK uncompressed and
///   page-aligned, and bionic's `dlopen` resolves bare names inside the APK,
///   which is also how the engine finds its CPU variants (R05 §4.3, PLAN
///   finding 10). A build without the prebuilt directory still succeeds; the
///   open fails here and the provider reports "engine unavailable".
/// * iOS: `SherpaEngine.framework/SherpaEngine` (the dynamic framework inside
///   SherpaEngine.xcframework from native/llama/build_ios.sh, embedded by
///   SwiftPM or CocoaPods). If an integrator links the engine statically into
///   the app instead, its `se_*` symbols are found in the process image.
/// * macOS / Linux / Windows: an explicit path ([kEngineLibraryEnv] or the
///   `path` argument), else the platform's default library name.
final class EngineLibrary {
  EngineLibrary._(this.library, this.bindings, this.locator);

  /// Opens and validates the library in the calling isolate. [path]
  /// overrides every default. Throws [EngineUnavailableException].
  factory EngineLibrary.open({String? path}) {
    final locator = path ?? defaultLocator();
    final DynamicLibrary lib;
    try {
      lib = _open(locator);
    } on Object catch (e) {
      throw EngineUnavailableException('the on-device engine library could not be loaded ($locator)', cause: e);
    }
    final SherpaEngineBindings b;
    try {
      b = SherpaEngineBindings(lib);
    } on Object catch (e) {
      throw EngineUnavailableException('the engine library is missing se_* symbols ($locator)', cause: e);
    }
    final abi = b.se_abi_version();
    if (abi != kSeAbiVersion) {
      throw EngineUnavailableException(
          'engine ABI $abi is not supported (this app speaks ABI $kSeAbiVersion); update the app or engine');
    }
    return EngineLibrary._(lib, b, locator);
  }

  final DynamicLibrary library;
  final SherpaEngineBindings bindings;

  /// What was opened: a path, a bare name, or `<process>`.
  final String locator;

  /// The locator used when no explicit path is given.
  static String defaultLocator() {
    final env = Platform.environment[kEngineLibraryEnv];
    if (env != null && env.isNotEmpty) return env;
    if (Platform.isAndroid || Platform.isLinux) return 'libsherpa_engine.so';
    if (Platform.isIOS) return 'SherpaEngine.framework/SherpaEngine';
    if (Platform.isMacOS) return 'libsherpa_engine.dylib';
    if (Platform.isWindows) return 'sherpa_engine.dll';
    return 'libsherpa_engine.so';
  }

  static DynamicLibrary _open(String locator) {
    if (locator == '<process>') return DynamicLibrary.process();
    try {
      return DynamicLibrary.open(locator);
    } on ArgumentError {
      if (Platform.isIOS) {
        // Statically linked into the Runner (an integrator's choice).
        final p = DynamicLibrary.process();
        if (p.providesSymbol('se_abi_version')) return p;
      }
      rethrow;
    }
  }
}

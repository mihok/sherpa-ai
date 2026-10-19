import 'package:sherpa_inference/sherpa_inference.dart';

/// Builds the engine host for this platform. [crashBreadcrumbPath] is
/// `EngineForensics.engineBreadcrumbPath`.
typedef EngineHostFactory = Future<EngineHost> Function({String? crashBreadcrumbPath});

/// The one place the app picks its engine host.
///
/// `createDefaultEngineHost` runs the engine in Android's private
/// `:inference` process (falling back to in-process FFI when the service
/// can't bind) and in-process everywhere else. To force in-process FFI,
/// replace the body with
/// `Future.value(FfiEngineHost(crashBreadcrumbPath: crashBreadcrumbPath))`.
Future<EngineHost> createLocalEngineHost({String? crashBreadcrumbPath}) =>
    createDefaultEngineHost(crashBreadcrumbPath: crashBreadcrumbPath);

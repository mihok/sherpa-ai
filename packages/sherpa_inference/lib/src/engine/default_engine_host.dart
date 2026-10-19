import 'dart:io';

import 'package:meta/meta.dart';

import '../ffi/library_loader.dart';
import 'engine_host.dart';
import 'ffi_engine_host.dart';
import 'process_engine_host.dart';
import 'process_exit.dart';
import 'process_messages.pigeon.dart';
import 'process_transport.dart';

/// The engine host this platform should use:
///
/// * **Android** ([useProcessHost], default true): a [ProcessEngineHost]
///   (engine in the private `:inference` process), once its service binds.
///   If it cannot bind — plugin not registered (e.g. a headless engine
///   without plugins), service missing from the merged manifest, binding
///   refused or timed out — it falls back to an in-process [FfiEngineHost].
///   A missing engine library is NOT a bind failure: the process host is
///   returned and reports "engine unavailable" on start, exactly as the FFI
///   host would.
/// * **Everywhere else** (iOS, host tests, desktop): [FfiEngineHost].
///
/// [crashBreadcrumbPath] should be `EngineForensics.engineBreadcrumbPath`.
Future<EngineHost> createDefaultEngineHost({
  String? crashBreadcrumbPath,
  String? backendDir,
  bool useProcessHost = true,
  BindPolicy bindPolicy = BindPolicy.adaptive,
  ProcessRestartPolicy restartPolicy = const ProcessRestartPolicy(),
  @visibleForTesting bool? isAndroid,
  @visibleForTesting InferenceTransport? transport,
  @visibleForTesting EngineHost Function()? ffiHost,
}) async {
  if (useProcessHost && (isAndroid ?? Platform.isAndroid)) {
    final host = ProcessEngineHost(
      transport: transport,
      crashBreadcrumbPath: crashBreadcrumbPath,
      backendDir: backendDir,
      bindPolicy: bindPolicy,
      restartPolicy: restartPolicy,
    );
    try {
      await host.bind();
      return host;
    } on EngineUnavailableException catch (e) {
      if (e.cause is! EngineHostBindException) return host;
    } on Object {
      // Anything else while binding: the in-process host still works.
    }
    await host.dispose();
  }
  return ffiHost?.call() ?? FfiEngineHost(crashBreadcrumbPath: crashBreadcrumbPath, backendDir: backendDir);
}

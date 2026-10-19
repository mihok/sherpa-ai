import 'dart:async';
import 'dart:io' show HttpException, OSError, SocketException, TlsException;

import 'package:flutter/foundation.dart' show FlutterError, immutable, visibleForTesting;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' as rp show ProviderException;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show EngineException;
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpHttpStatusException, McpRpcException, McpTransportException;

/// One app-level error as the diagnostics export keeps it: when, where it
/// was caught, the error's type name and a short code. Never the message,
/// arguments or stack: a provider exception can echo a request, and a
/// `FormatException` can quote the text it failed on.
@immutable
final class AppErrorRecord {
  const AppErrorRecord({required this.at, required this.source, required this.type, this.code});

  final DateTime at;

  /// Where it was caught: `flutter` (FlutterError.onError), `platform`
  /// (PlatformDispatcher.onError), `provider` (a Riverpod provider failed),
  /// or a feature name.
  final String source;

  /// `runtimeType` of the error (minified in obfuscated builds).
  final String type;

  /// A short machine code when the error type has one: `network`,
  /// `http_429`, `rpc_-32602`, `os_111`, the engine's status name, …
  final String? code;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'source': source,
        'type': type,
        if (code != null) 'code': code,
      };
}

/// The last [capacity] app-level errors, in memory only (nothing is
/// persisted, so a restart starts empty). Fed by the global error handlers
/// in bootstrap and by [AppErrorObserver]; read by the diagnostics export.
final class AppErrorRing {
  AppErrorRing({this.capacity = 50, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The app-wide ring the handlers write to.
  static final AppErrorRing instance = AppErrorRing();

  final int capacity;
  final DateTime Function() _now;
  final List<AppErrorRecord> _records = [];
  int _dropped = 0;

  /// Oldest first.
  List<AppErrorRecord> get records => List.unmodifiable(_records);

  /// How many older records fell out of the ring.
  int get dropped => _dropped;

  /// Keeps the type name and code of [error]; never its message.
  void record(Object error, {String source = 'app'}) {
    // A provider that read a failed provider rethrows its error wrapped.
    while (error is rp.ProviderException) {
      error = error.exception;
    }
    _records.add(AppErrorRecord(at: _now(), source: _safeSource(source), type: typeNameOf(error), code: codeOf(error)));
    while (_records.length > capacity) {
      _records.removeAt(0);
      _dropped++;
    }
  }

  /// The newest [n], newest last.
  List<AppErrorRecord> last(int n) => _records.length <= n ? records : List.unmodifiable(_records.sublist(_records.length - n));

  @visibleForTesting
  void clear() {
    _records.clear();
    _dropped = 0;
  }

  static final RegExp _sourceShape = RegExp(r'^[a-z][a-z0-9_.-]{0,31}$');

  static String _safeSource(String s) => _sourceShape.hasMatch(s) ? s : 'app';

  /// Type names only ever contain identifier characters, generics and
  /// spaces; anything else (a custom `runtimeType` override) is dropped.
  static final RegExp _typeShape = RegExp(r'^[A-Za-z0-9_$<>, ?]{1,80}$');

  static String typeNameOf(Object error) {
    final name = error.runtimeType.toString();
    return _typeShape.hasMatch(name) ? name : 'Object';
  }

  /// A short code for the error types Sherpa knows; null otherwise.
  static String? codeOf(Object error) => switch (error) {
        ProviderException(:final kind, :final statusCode) =>
          statusCode == null ? kind.name : '${kind.name}_$statusCode',
        McpRpcException(:final code) => 'rpc_$code',
        McpHttpStatusException(:final statusCode) => 'http_$statusCode',
        McpTransportException(:final statusCode) => statusCode == null ? 'transport' : 'http_$statusCode',
        EngineException(:final codeName) => _ident(codeName),
        SocketException(:final osError) => osError == null ? 'socket' : 'os_${osError.errorCode}',
        OSError(:final errorCode) => 'os_$errorCode',
        HttpException() => 'http',
        TlsException() => 'tls',
        TimeoutException() => 'timeout',
        CancelledException() => 'cancelled',
        PlatformException(:final code) => _ident(code),
        MissingPluginException() => 'missing_plugin',
        FlutterError() => null,
        _ => null,
      };

  static final RegExp _identShape = RegExp(r'^[A-Za-z0-9_.-]{1,40}$');

  /// [s] when it looks like a code, else null (a platform error "code"
  /// can be free text).
  static String? _ident(String s) => _identShape.hasMatch(s) ? s : null;
}

/// The app-wide ring, for widgets and the diagnostics export.
final appErrorRingProvider = Provider<AppErrorRing>((ref) => AppErrorRing.instance);

/// Records every provider that fails (a failed `FutureProvider`, a
/// throwing `build`) in [AppErrorRing.instance], by type and code only.
/// Pass it to the root `ProviderScope(observers: [AppErrorObserver()])`.
final class AppErrorObserver extends ProviderObserver {
  const AppErrorObserver({AppErrorRing? ring}) : _ring = ring;

  final AppErrorRing? _ring;

  @override
  void providerDidFail(ProviderObserverContext context, Object error, StackTrace stackTrace) {
    // Cancellation and "not wired in this build" are expected, not errors;
    // a provider that only rethrows a dependency's failure (wrapped) was
    // recorded when that dependency failed.
    if (error is CancelledException || error is UnimplementedError || error is rp.ProviderException) return;
    (_ring ?? AppErrorRing.instance).record(error, source: 'provider');
  }
}

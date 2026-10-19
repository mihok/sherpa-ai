import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_platform/sherpa_platform.dart';

import '../../app_info.dart';

/// The built-in `device` server's facts from sherpa_platform's
/// [DeviceSnapshot] (OS version, model) plus the locale and time zone the
/// app sees. Nothing identifying: no device ids, no account names.
///
/// Read on every call (the time zone and locale can change); a failing
/// plugin falls back to what Flutter knows.
final class PlatformDeviceFactsProvider implements DeviceFactsProvider {
  PlatformDeviceFactsProvider({PlatformBackend? backend, DateTime Function()? now})
      : _backend = backend,
        _now = now ?? DateTime.now;

  final PlatformBackend? _backend;
  final DateTime Function() _now;
  DeviceSnapshot? _snapshot;

  @override
  Future<DeviceFacts> deviceFacts() async {
    var snap = _snapshot;
    if (snap == null) {
      try {
        snap = _snapshot = await DeviceSnapshot.capture(backend: _backend);
      } on Object {
        snap = null;
      }
    }
    final now = _now();
    final model = [snap?.manufacturer, snap?.model].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    return DeviceFacts(
      appName: AppInfo.name,
      appVersion: AppInfo.version,
      platform: snap?.platform.name ?? defaultTargetPlatform.name,
      osVersion: snap?.osVersion,
      deviceModel: model.isEmpty ? null : model,
      locale: PlatformDispatcher.instance.locale.toLanguageTag(),
      timeZone: now.timeZoneName,
      timeZoneOffset: now.timeZoneOffset,
    );
  }
}

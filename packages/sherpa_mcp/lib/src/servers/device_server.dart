/// The built-in `device` server: time, time zone, locale, app and device.
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show Clock, JsonMap, SystemClock, ToolAnnotations, compact;

import '../protocol/types.dart';
import 'dart_server.dart';

/// What the app knows about itself and the device (from sherpa_platform;
/// named apart from its pigeon `DeviceInfo` so both can be imported).
@immutable
final class DeviceFacts {
  const DeviceFacts({
    required this.appName,
    required this.appVersion,
    required this.platform,
    required this.locale,
    required this.timeZoneOffset,
    this.osVersion,
    this.deviceModel,
    this.timeZone,
    this.extra = const {},
  });

  final String appName;
  final String appVersion;

  /// `android` / `ios` / …
  final String platform;
  final String? osVersion;
  final String? deviceModel;

  /// BCP 47, e.g. `de-CH`.
  final String locale;

  /// IANA id when known (`Europe/Zurich`), else an abbreviation.
  final String? timeZone;

  /// The local offset from UTC right now.
  final Duration timeZoneOffset;

  /// Anything else worth telling the model (keep it non-identifying).
  final Map<String, String> extra;
}

/// Supplies [DeviceFacts] (read each call: the time zone can change).
abstract interface class DeviceFactsProvider {
  Future<DeviceFacts> deviceFacts();
}

/// A fixed [DeviceFacts] (tests).
final class StaticDeviceFactsProvider implements DeviceFactsProvider {
  const StaticDeviceFactsProvider(this.info);

  final DeviceFacts info;

  @override
  Future<DeviceFacts> deviceFacts() async => info;
}

String _offset(Duration d) {
  final sign = d.isNegative ? '-' : '+';
  final m = d.inMinutes.abs();
  return '$sign${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

const List<String> _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// The `device` on-device MCP server. Every tool is read-only, idempotent
/// and closed-world, so for a trusted server they run without asking.
/// Nothing identifying (no device ids, no account names) is exposed.
DartMcpServer deviceMcpServer({required DeviceFactsProvider provider, Clock clock = const SystemClock()}) {
  const readOnly = ToolAnnotations(readOnlyHint: true, idempotentHint: true, openWorldHint: false);
  return DartMcpServer(
    info: const McpImplementation(name: 'sherpa-device', title: 'Device', version: '1.0.0'),
    tools: [
      DartMcpTool(
        name: 'current_time',
        title: 'Current time',
        description: "The current date and time in the user's time zone, with the UTC time and the weekday.",
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        annotations: const ToolAnnotations(
          title: 'Current time',
          readOnlyHint: true,
          idempotentHint: true,
          openWorldHint: false,
        ),
        handler: (args, ctx) async {
          final info = await provider.deviceFacts();
          final utc = clock.now().toUtc();
          final local = utc.add(info.timeZoneOffset);
          final offset = _offset(info.timeZoneOffset);
          final localIso = '${local.toIso8601String().replaceFirst('Z', '').split('.').first}$offset';
          final utcIso = '${utc.toIso8601String().split('.').first}Z';
          final weekday = _weekdays[local.weekday - 1];
          final zone = info.timeZone ?? 'UTC$offset';
          return DartToolResult.text(
            'It is $weekday, $localIso (time zone $zone, UTC$offset). UTC: $utcIso.',
            structuredContent: compact({
              'local': localIso,
              'utc': utcIso,
              'weekday': weekday,
              'timeZone': info.timeZone,
              'utcOffset': offset,
              'utcOffsetMinutes': info.timeZoneOffset.inMinutes,
              'locale': info.locale,
            }),
          );
        },
      ),
      DartMcpTool(
        name: 'device_info',
        title: 'App and device',
        description: 'Facts about the app and the device: app version, platform and OS version, device model, '
            'language and region settings.',
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        annotations: readOnly,
        handler: (args, ctx) async {
          final i = await provider.deviceFacts();
          final JsonMap facts = compact({
            'app': '${i.appName} ${i.appVersion}',
            'platform': i.platform,
            'osVersion': i.osVersion,
            'deviceModel': i.deviceModel,
            'locale': i.locale,
            'timeZone': i.timeZone,
            ...i.extra,
          });
          return DartToolResult.text(
            facts.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
            structuredContent: facts,
          );
        },
      ),
    ],
  );
}

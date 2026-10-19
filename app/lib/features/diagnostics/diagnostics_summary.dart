import '../models/widgets/format.dart' show formatBytes;

/// The readable summary of a diagnostics bundle ("Copy summary"), built
/// only from the bundle's own (already redacted) data.
String diagnosticsSummary(Map<String, Object?> d) {
  final b = StringBuffer();
  Map<String, Object?> obj(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
  List<Object?> list(Object? v) => v is List ? v : const [];
  String? unavailable(Object? v) => v is Map && v['unavailable'] != null ? 'unavailable (${v['unavailable']})' : null;
  String join(Iterable<String?> parts) => parts.whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  final app = obj(d['app']);
  b
    ..writeln('Sherpa diagnostics (${d['generatedAt'] ?? ''})')
    ..writeln(join([
      'App ${app['version'] ?? '?'}${app['build'] == null ? '' : ' (${app['build']})'} ${app['buildMode'] ?? ''}'.trim(),
      'Flutter ${app['flutter'] ?? '?'}',
      'Dart ${app['dart'] ?? '?'}',
    ]));

  final os = obj(d['os']);
  final dev = obj(d['device']);
  final cpu = obj(dev['cpu']);
  b.writeln('Device: ${unavailable(d['device']) ?? join([
        dev['displayModel'] as String?,
        _os(os),
        dev['socModel'] == null ? null : 'SoC ${[dev['socManufacturer'], dev['socModel']].whereType<String>().join(' ')}',
        dev['totalRamBytes'] is int ? 'RAM ${formatBytes(dev['totalRamBytes']! as int)}' : null,
        dev['availableRamBytes'] is int ? '${formatBytes(dev['availableRamBytes']! as int)} available' : null,
        cpu['cores'] == null ? null : '${cpu['cores']} cores (${cpu['performanceCores'] ?? '?'} big)',
        dev['cpuClass'] == null ? null : 'CPU class ${dev['cpuClass']}',
        'thermal ${dev['thermal'] ?? '?'}',
        'battery saver ${dev['batterySaver'] == true ? 'on' : 'off'}',
      ])}');

  final exit = d['lastExit'];
  if (exit is Map) {
    b.writeln('Last exit: ${join([
          '${exit['kind']}',
          '${exit['reasonName']}',
          exit['description'] as String?,
          '${exit['at']}',
          if (obj(exit['processState']).isNotEmpty) 'while ${obj(exit['processState'])['phase']}',
        ])}');
  }

  final engine = obj(d['engine']);
  if (unavailable(d['engine']) case final String u) {
    b.writeln('Engine: $u');
  } else if (engine['wired'] != true) {
    b.writeln('Engine: not wired in this build');
  } else {
    final sys = obj(engine['systemInfo']);
    final backends = [for (final x in list(sys['backends'])) obj(x)['name']].whereType<String>();
    b.writeln('Engine: ${join([
          engine['state'] as String?,
          engine['hostKind'] as String?,
          engine['engineVersion'] as String?,
          sys['cpu_variant'] is String && (sys['cpu_variant']! as String).isNotEmpty ? 'CPU variant ${sys['cpu_variant']}' : null,
          backends.isEmpty ? null : 'backends ${backends.join(', ')}',
          engine['reason'] as String?,
        ])}');
    final crash = engine['lastCrash'];
    b.writeln(crash is Map
        ? 'Last engine crash: ${join([
            'while ${crash['phase']}',
            crash['contextTokens'] == null ? null : '${crash['contextTokens']}-token context',
            crash['nativeAbort'] == true ? 'native abort: ${crash['engineMessage']}' : 'no abort message (possibly an OS kill)',
          ])}'
        : 'Last engine crash: none');
  }

  final models = d['localModels'];
  if (models is List) {
    b.writeln('On-device models (${models.length})${models.isEmpty ? '' : ':'}');
    for (final m in models.map(obj)) {
      b.writeln('  - ${join([
            m['id'] as String?,
            m['repo'] as String? ?? m['source'] as String?,
            m['format'] as String?,
            m['quant'] as String?,
            m['sizeBytes'] is int ? formatBytes(m['sizeBytes']! as int) : null,
            m['issue'] == 'none' ? null : 'issue ${m['issue']}',
          ])}');
    }
  } else {
    b.writeln('On-device models: ${unavailable(models) ?? 'none'}');
  }

  final providers = d['providers'];
  if (providers is List) {
    b.writeln('Model providers (${providers.length})${providers.isEmpty ? '' : ':'}');
    for (final p in providers.map(obj)) {
      final used = obj(p['modelsInChats']).keys;
      b.writeln('  - ${join([
            '${p['ref']}',
            p['flavor'] as String?,
            p['host'] as String?,
            p['location'] as String?,
            p['unverifiedLocal'] == true ? 'unverified local' : null,
            p['apiKeySet'] == true ? 'key set' : (p['apiKeySet'] == false ? 'no key' : null),
            p['defaultModelId'] == null ? null : 'default ${p['defaultModelId']}',
            used.isEmpty ? null : 'used: ${used.join(', ')}',
          ])}');
    }
  } else {
    b.writeln('Model providers: ${unavailable(providers)}');
  }
  final def = obj(d['defaultModel']);
  if (def.isNotEmpty && def['unavailable'] == null) b.writeln('Default model: ${def['provider']} / ${def['modelId']}');

  final mcp = d['mcpServers'];
  if (mcp is List) {
    b.writeln('Tool servers (${mcp.length})${mcp.isEmpty ? '' : ':'}');
    for (final s in mcp.map(obj)) {
      b.writeln('  - ${join([
            '${s['ref']}',
            s['host'] as String?,
            s['era'] as String?,
            s['status'] as String?,
            '${s['toolCount'] ?? 0} tools',
            s['lastErrorCode'] == null ? null : 'last error ${s['lastErrorCode']}',
          ])}');
    }
  } else {
    b.writeln('Tool servers: ${unavailable(mcp)}');
  }

  final ctx = obj(d['context']);
  final settings = obj(ctx['settings']);
  final thresholds = obj(settings['thresholds']);
  b.writeln('Context: ${unavailable(d['context']) ?? join([
        ctx['manager'] as String?,
        thresholds.isEmpty ? null : 'prune ${thresholds['prune']} / compact ${thresholds['compact']} / handoff ${thresholds['handoff']}',
        'auto-compact ${settings['autoCompact'] == true ? 'on' : 'off'}',
        'model summaries ${ctx['modelWrittenSummaries'] == true ? 'on' : 'off'}',
      ])}');

  final data = obj(d['data']);
  b.writeln('Data: ${unavailable(d['data']) ?? join([
        '${_count(data['chats'], 'chat')} (${data['archivedChats'] ?? 0} archived)',
        '${_count(data['messages'], 'message')}${data['messagesTruncated'] == true ? ' or more' : ''}',
        data['databaseBytes'] is int ? 'database ${formatBytes(data['databaseBytes']! as int)}' : 'storage ${data['storage']}',
      ])}');

  final errors = obj(d['errors']);
  final recent = list(errors['recent']).map(obj).toList();
  b.writeln('Recent errors: ${unavailable(d['errors']) ?? (recent.isEmpty ? 'none' : '${recent.length}'
      '${(errors['dropped'] as int? ?? 0) > 0 ? ' (${errors['dropped']} older dropped)' : ''}')}');
  for (final e in recent.reversed.take(10)) {
    b.writeln('  - ${join(['${e['at']}', '${e['source']}', '${e['type']}', e['code'] as String?])}');
  }

  final perf = obj(d['perfLab']);
  final perfModels = list(perf['models']).map(obj).toList();
  if (perf['available'] == true && perfModels.isNotEmpty) {
    b.writeln('Performance lab:');
    for (final m in perfModels) {
      b.writeln('  - ${join([
            m['id'] as String?,
            '${m['runs']} runs',
            'decode ${m['decodeTps']} tok/s',
            'prefill ${m['prefillTps']} tok/s',
            'first token ${m['ttftMs']} ms',
            m['backend'] as String?,
          ])}');
    }
  } else {
    b.writeln('Performance lab: ${unavailable(d['perfLab']) ?? (perf['available'] == true ? 'no runs' : 'not available')}');
  }
  return b.toString().trimRight();
}

/// "1 chat", "3 chats", "? chats".
String _count(Object? n, String noun) => n is int ? '$n ${n == 1 ? noun : '${noun}s'}' : '? ${noun}s';

String? _os(Map<String, Object?> os) {
  final platform = os['platform'];
  if (platform == null) return null;
  final name = switch (platform) {
    'android' => 'Android',
    'ios' => 'iOS',
    _ => '$platform',
  };
  final api = os['apiLevel'] == null ? '' : ' (API ${os['apiLevel']})';
  return '$name ${os['version'] ?? ''}$api'.replaceAll('  ', ' ').trim();
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../../../app_info.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../handoff/handoff_service.dart' show scrubSecrets;

/// "Export my data": every chat (all branches, not just the visible one)
/// with its context overlays, plan, run checkpoint and audit trail, plus
/// provider settings and preferences, as one JSON archive.
///
/// Secrets never enter it, in three layers:
/// 1. nothing is read from the [SecretStore] *for* the archive: API keys and
///    tokens live only there, and provider configs hold no keys;
/// 2. every string goes through [scrubSecrets] (token-shaped text a user
///    pasted into a chat, `password=…`, secret query parameters), and
///    header values that look like credentials are masked;
/// 3. as a last net, every value currently in the secret store is masked
///    wherever it appears verbatim (a key pasted in a format no pattern
///    knows). The values are held in memory only while masking.
///
/// It lives with the context feature because the archive carries the same
/// session data the inspector shows (overlays, summaries, audit) and the
/// same scrubber as handoff bundles; the privacy dashboard only calls it.
final class DataExporter {
  DataExporter({
    required this.sessions,
    required this.providers,
    required this.preferences,
    required this.secrets,
    required this.clock,
    this.ui,
    this.appVersion = AppInfo.version,
  });

  final SessionStore sessions;
  final ProviderRegistry providers;
  final PreferencesStore preferences;
  final SecretStore secrets;
  final UiPreferencesStore? ui;
  final Clock clock;
  final String appVersion;

  static const String format = 'sherpa.export';
  static const int version = 1;

  /// Secrets shorter than this are not masked by value: a 4-character
  /// value would blank out ordinary words (patterns still apply).
  static const int minMaskedSecretLength = 8;

  /// Guards the branch walk against a corrupted (cyclic) tree.
  static const int maxMessagesPerSession = 200000;

  /// The archive as JSON-safe data.
  Future<JsonMap> archive() async {
    final out = <JsonMap>[];
    for (final s in await sessions.listSessions(includeArchived: true)) {
      out.add({
        'session': s.toJson(),
        'messages': [for (final m in await _allMessages(s.id)) m.toJson()],
        'overlays': [for (final o in await sessions.overlays(s.id)) o.toJson()],
        'plan': (await sessions.getPlan(s.id))?.toJson(),
        'checkpoint': (await sessions.getCheckpoint(s.id))?.toJson(),
        'audit': [for (final a in await sessions.audit(s.id)) a.toJson()],
      });
    }
    final prefs = preferences;
    final choice = prefs.defaultModel;
    final raw = <String, Object?>{
      'format': format,
      'version': version,
      'exportedAt': clock.now().toUtc().toIso8601String(),
      'app': {'name': AppInfo.name, 'version': appVersion},
      'notice': 'Exported by Sherpa. API keys, tokens and passwords are never included; '
          'text that looked like a secret was replaced by ${Redactor.mask}.',
      'preferences': {
        'defaultModel': choice == null ? null : {'providerId': choice.providerId, 'modelId': choice.modelId},
        'onboardingComplete': prefs.onboardingComplete,
        if (ui != null) 'ui': ui!.settings.toJson(),
      },
      'providers': [
        for (final c in providers.configs)
          {
            ...c.toJson(),
            'baseUrl': Redactor.uri(c.baseUrl).toString(),
            'headers': Redactor.headers(c.headers),
          },
      ],
      'sessions': out,
    };
    final known = await _secretValues();
    String mask(String s) {
      var v = scrubSecrets(s);
      for (final secret in known) {
        if (v.contains(secret)) v = v.replaceAll(secret, Redactor.mask);
      }
      return v;
    }

    return _mapStrings(raw, mask)! as JsonMap;
  }

  /// [archive] encoded as indented UTF-8 JSON.
  Future<Uint8List> archiveBytes() async =>
      utf8.encode(const JsonEncoder.withIndent(' ').convert(await archive()));

  /// `sherpa-export-2026-10-19-1405.json`.
  String fileName() {
    final d = clock.now().toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'sherpa-export-${d.year}-${two(d.month)}-${two(d.day)}-${two(d.hour)}${two(d.minute)}.json';
  }

  /// Every message of every branch: breadth-first from the roots.
  Future<List<Message>> _allMessages(String sessionId) async {
    final out = <Message>[];
    final seen = <String>{};
    final queue = <String?>[null];
    while (queue.isNotEmpty && out.length < maxMessagesPerSession) {
      final parent = queue.removeAt(0);
      for (final m in await sessions.children(sessionId, parent)) {
        if (!seen.add(m.id)) continue;
        out.add(m);
        queue.add(m.id);
      }
    }
    return out;
  }

  Future<List<String>> _secretValues() async {
    final values = <String>{};
    for (final key in await secrets.keys()) {
      final v = await secrets.read(key);
      if (v != null && v.length >= minMaskedSecretLength) values.add(v);
    }
    // Longest first, so a secret containing another is masked whole.
    return values.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  static Object? _mapStrings(Object? v, String Function(String) f) => switch (v) {
        final String s => f(s),
        final Map<String, Object?> m => {for (final e in m.entries) e.key: _mapStrings(e.value, f)},
        final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': _mapStrings(e.value, f)},
        final List<Object?> l => [for (final e in l) _mapStrings(e, f)],
        _ => v,
      };
}

final dataExporterProvider = Provider<DataExporter>(
  (ref) => DataExporter(
    sessions: ref.watch(sessionStoreProvider),
    providers: ref.watch(providerRegistryProvider),
    preferences: ref.watch(preferencesProvider),
    secrets: ref.watch(secretStoreProvider),
    ui: ref.watch(uiPreferencesStoreProvider),
    clock: ref.watch(clockProvider),
  ),
);

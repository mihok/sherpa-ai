/// Per-server host settings for M5: sampling permission and limits, MCP
/// Apps on/off, and the network consents given to app views. Stored in the
/// encrypted document store through [McpRecords]; nothing here is secret.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart' show Clock, JsonMap, JsonMapRead, SystemClock, compact;

import '../../../state/services.dart' show ModelChoice;
import '../mcp_records.dart';

/// Whether a server may use the user's model (`sampling/createMessage`).
/// Sampling is deprecated in 2026-07-28 and off by default (PLAN §7.5).
enum McpSamplingMode {
  /// Not declared to the server; any request is refused.
  off,

  /// Declared; every request shows the approval sheet first (with "Allow
  /// for this chat"), and every answer is reviewed before it is sent.
  ask,

  /// Declared; requests made during a chat skip the approval sheet, the
  /// answer is still reviewed. Requests outside a chat still ask.
  allowInChats,
}

/// One server's settings.
@immutable
final class McpServerHostSettings {
  const McpServerHostSettings({
    this.sampling = McpSamplingMode.off,
    this.samplingMaxTokens = defaultMaxTokens,
    this.samplingPerMinute = defaultPerMinute,
    this.samplingModel,
    this.appsEnabled = true,
  });

  factory McpServerHostSettings.fromJson(JsonMap j) {
    final model = j.optObj('samplingModel');
    return McpServerHostSettings(
      sampling: McpSamplingMode.values.where((m) => m.name == j['sampling']).firstOrNull ?? McpSamplingMode.off,
      samplingMaxTokens: (j.optInt('samplingMaxTokens') ?? defaultMaxTokens).clamp(16, maxTokensCeiling),
      samplingPerMinute: (j.optInt('samplingPerMinute') ?? defaultPerMinute).clamp(1, 30),
      samplingModel: model == null || model['providerId'] is! String || model['modelId'] is! String
          ? null
          : ModelChoice(providerId: model['providerId']! as String, modelId: model['modelId']! as String),
      appsEnabled: j.opt<bool>('appsEnabled') ?? true,
    );
  }

  static const int defaultMaxTokens = 1024;
  static const int defaultPerMinute = 3;

  /// No server gets more than this per request, whatever it asks.
  static const int maxTokensCeiling = 8192;

  /// Choices offered in settings.
  static const List<int> maxTokenChoices = [256, 1024, 4096];
  static const List<int> perMinuteChoices = [1, 3, 10];

  final McpSamplingMode sampling;

  /// Cap on `maxTokens` per request.
  final int samplingMaxTokens;

  /// Requests per minute; more are refused.
  final int samplingPerMinute;

  /// The model sampling uses; null: the chat's current model, else the
  /// app's default model.
  final ModelChoice? samplingModel;

  /// MCP Apps: declare the UI extension to this server and render its
  /// views. Off: tool results show as text.
  final bool appsEnabled;

  bool get samplingDeclared => sampling != McpSamplingMode.off;

  McpServerHostSettings copyWith({
    McpSamplingMode? sampling,
    int? samplingMaxTokens,
    int? samplingPerMinute,
    ModelChoice? samplingModel,
    bool clearSamplingModel = false,
    bool? appsEnabled,
  }) =>
      McpServerHostSettings(
        sampling: sampling ?? this.sampling,
        samplingMaxTokens: samplingMaxTokens ?? this.samplingMaxTokens,
        samplingPerMinute: samplingPerMinute ?? this.samplingPerMinute,
        samplingModel: clearSamplingModel ? null : (samplingModel ?? this.samplingModel),
        appsEnabled: appsEnabled ?? this.appsEnabled,
      );

  JsonMap toJson() => compact({
        'sampling': sampling.name,
        'samplingMaxTokens': samplingMaxTokens,
        'samplingPerMinute': samplingPerMinute,
        'samplingModel': samplingModel == null
            ? null
            : {'providerId': samplingModel!.providerId, 'modelId': samplingModel!.modelId},
        'appsEnabled': appsEnabled ? null : false,
      });
}

/// The network a user allowed (or refused: an empty set) for one app view
/// resource: per server plus the resource's SHA-256, so a changed UI asks
/// again (R03 §11.8).
@immutable
final class McpAppNetworkConsent {
  const McpAppNetworkConsent({
    required this.serverId,
    required this.resourceSha256,
    required this.resourceUri,
    required this.origins,
    required this.decidedAt,
  });

  factory McpAppNetworkConsent.fromJson(JsonMap j) => McpAppNetworkConsent(
        serverId: j.req<String>('serverId'),
        resourceSha256: j.req<String>('sha256'),
        resourceUri: j.opt<String>('resourceUri') ?? '',
        origins: {for (final o in j.opt<List<Object?>>('origins') ?? const <Object?>[]) if (o is String) o},
        decidedAt: j.optDate('decidedAt') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final String serverId;
  final String resourceSha256;
  final String resourceUri;

  /// `CspOrigin.source` strings; empty: the user kept the view offline.
  final Set<String> origins;
  final DateTime decidedAt;

  JsonMap toJson() => {
        'serverId': serverId,
        'sha256': resourceSha256,
        'resourceUri': resourceUri,
        'origins': origins.toList()..sort(),
        'decidedAt': decidedAt.toUtc().toIso8601String(),
      };
}

/// [McpServerHostSettings] and [McpAppNetworkConsent]s, loaded once and
/// written through.
final class McpHostSettingsStore {
  McpHostSettingsStore._(this._records, this._clock);

  static const String settingsCollection = 'mcp_host_settings';
  static const String consentCollection = 'mcp_app_consents';

  static Future<McpHostSettingsStore> load(McpRecords records, {Clock clock = const SystemClock()}) async {
    final s = McpHostSettingsStore._(records, clock);
    for (final doc in await records.list(settingsCollection)) {
      final id = doc['serverId'];
      if (id is! String) continue;
      try {
        s._settings[id] = McpServerHostSettings.fromJson(doc);
      } on Object {
        // Written by a newer version, or damaged: defaults.
      }
    }
    for (final doc in await records.list(consentCollection)) {
      try {
        final c = McpAppNetworkConsent.fromJson(doc);
        s._consents[_consentId(c.serverId, c.resourceSha256)] = c;
      } on Object {
        // Ignore: the view asks again.
      }
    }
    return s;
  }

  final McpRecords _records;
  final Clock _clock;
  final Map<String, McpServerHostSettings> _settings = {};
  final Map<String, McpAppNetworkConsent> _consents = {};
  final Map<String, Set<String>> _chatGrants = {};
  final StreamController<String> _changes = StreamController<String>.broadcast();

  /// Server ids whose settings, consents or chat grants changed.
  Stream<String> get changes => _changes.stream;

  void _changed(String serverId) {
    if (!_changes.isClosed) _changes.add(serverId);
  }

  McpServerHostSettings of(String serverId) => _settings[serverId] ?? const McpServerHostSettings();

  Future<void> update(String serverId, McpServerHostSettings settings) async {
    _settings[serverId] = settings;
    if (settings.sampling == McpSamplingMode.off) _chatGrants.remove(serverId);
    _changed(serverId);
    await _records.put(settingsCollection, serverId, {...settings.toJson(), 'serverId': serverId});
  }

  // ------------------------------------------------------------ sampling grants

  /// "Allow for this chat" answers (this app run only).
  bool chatAllowed(String serverId, String sessionId) => _chatGrants[serverId]?.contains(sessionId) ?? false;

  Set<String> chatGrants(String serverId) => Set.unmodifiable(_chatGrants[serverId] ?? const <String>{});

  void allowChat(String serverId, String sessionId) {
    if ((_chatGrants[serverId] ??= {}).add(sessionId)) _changed(serverId);
  }

  void revokeChatGrants(String serverId) {
    if (_chatGrants.remove(serverId) != null) _changed(serverId);
  }

  /// A deleted chat's grants go with it.
  void forgetSession(String sessionId) {
    for (final e in _chatGrants.entries) {
      if (e.value.remove(sessionId)) _changed(e.key);
    }
  }

  // ------------------------------------------------------------ app network consent

  static String _consentId(String serverId, String sha256) => '$serverId|$sha256';

  /// What the user decided for this server + resource hash; null: ask.
  Set<String>? grantedOrigins(String serverId, String sha256) => _consents[_consentId(serverId, sha256)]?.origins;

  List<McpAppNetworkConsent> consentsOf(String serverId) =>
      [for (final c in _consents.values) if (c.serverId == serverId) c]..sort((a, b) => b.decidedAt.compareTo(a.decidedAt));

  Future<void> setGrantedOrigins(String serverId, String sha256, Set<String> origins, {String resourceUri = ''}) async {
    final c = McpAppNetworkConsent(
      serverId: serverId,
      resourceSha256: sha256,
      resourceUri: resourceUri,
      origins: {...origins},
      decidedAt: _clock.now(),
    );
    final id = _consentId(serverId, sha256);
    _consents[id] = c;
    _changed(serverId);
    await _records.put(consentCollection, id, c.toJson());
  }

  /// Forgets one decision: the view asks again next time.
  Future<void> revokeConsent(String serverId, String sha256) async {
    final id = _consentId(serverId, sha256);
    if (_consents.remove(id) == null) return;
    _changed(serverId);
    await _records.delete(consentCollection, id);
  }

  /// Everything about a removed server.
  Future<void> forgetServer(String serverId) async {
    for (final c in consentsOf(serverId)) {
      await revokeConsent(serverId, c.resourceSha256);
    }
    _chatGrants.remove(serverId);
    if (_settings.remove(serverId) != null) await _records.delete(settingsCollection, serverId);
    _changed(serverId);
  }

  /// "Delete all data": every server's settings and consents.
  Future<void> eraseAll() async {
    final servers = {..._settings.keys, for (final c in _consents.values) c.serverId};
    for (final id in [..._consents.keys]) {
      await _records.delete(consentCollection, id);
    }
    for (final id in [..._settings.keys]) {
      await _records.delete(settingsCollection, id);
    }
    _consents.clear();
    _settings.clear();
    _chatGrants.clear();
    servers.forEach(_changed);
  }

  Future<void> dispose() => _changes.close();
}

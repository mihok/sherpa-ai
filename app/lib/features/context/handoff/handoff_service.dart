import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../../../app_info.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';

/// The scrubber for everything that leaves the device in a handoff or an
/// export: `sherpa_net`'s [Redactor.text] (the app-wide secret patterns),
/// then the core's [HandoffScrubbers.basic], which also catches
/// `password=…` assignments and secret query parameters. Two passes on
/// purpose: neither list can know every token format, and a false
/// positive costs a word while a miss leaks a credential.
String scrubSecrets(String text) => HandoffScrubbers.basic(Redactor.text(text));

/// Builds handoff bundles from chats and starts chats from bundles.
///
/// Free of the chat feature on purpose: import runs from the home screen
/// and settings, where no chat is open.
final class HandoffService {
  HandoffService({
    required this.store,
    required this.registry,
    required this.clock,
    required this.ids,
    this.appVersion = AppInfo.version,
    this.strategy = const ExtractiveContextStrategy(),
  });

  final SessionStore store;
  final ProviderRegistry registry;
  final Clock clock;
  final IdGenerator ids;
  final String appVersion;

  /// Extractive: deterministic, offline and free, so building a handoff
  /// never sends the conversation anywhere (and works when the context
  /// is already too full for a model-written summary).
  final ContextStrategy strategy;

  /// A bundle for [sessionId] as [model] would continue it. Every free-text
  /// field is scrubbed with [scrubSecrets]; [notes] travel with it.
  Future<HandoffBundle> build({
    required String sessionId,
    ModelChoice? model,
    String? notes,
    int recentUserTurns = 1,
  }) async {
    final session = await store.getSession(sessionId) ?? (throw StateError('unknown session $sessionId'));
    var kind = 'unknown';
    var location = ExecutionLocation.remote;
    final providerId = model?.providerId ?? session.providerId;
    if (providerId != null) {
      try {
        final info = (await registry.resolve(providerId)).info;
        kind = info.kind.name;
        location = info.location;
      } on Object {
        // A removed provider still has a model id worth recording.
      }
    }
    final trimmed = notes?.trim();
    return HandoffBuilder(store: store, strategy: strategy, scrub: scrubSecrets, clock: clock).build(
      sessionId: sessionId,
      source: HandoffSource(
        appVersion: appVersion,
        providerKind: kind,
        modelId: model?.modelId ?? session.modelId ?? 'unknown',
        location: location,
        sessionId: sessionId,
      ),
      recentUserTurns: recentUserTurns,
      notes: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }

  /// A new chat seeded from [bundle] (pinned `MessageKind.handoff` seed +
  /// acknowledgement + plan), on [model] when given.
  Future<SessionRecord> start(
    HandoffBundle bundle, {
    ModelChoice? model,
    String? fromSessionId,
    String? systemPrompt,
  }) =>
      startSessionFromHandoff(
        store: store,
        bundle: bundle,
        sessionId: ids.next('chat'),
        ids: ids,
        clock: clock,
        fromSessionId: fromSessionId,
        providerId: model?.providerId,
        modelId: model?.modelId,
        systemPrompt: systemPrompt,
      );
}

final handoffServiceProvider = Provider<HandoffService>(
  (ref) => HandoffService(
    store: ref.watch(sessionStoreProvider),
    registry: ref.watch(providerRegistryProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  ),
);

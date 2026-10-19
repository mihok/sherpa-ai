import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show databaseKeySecretName;

import '../../../state/providers.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../handoff/handoff_platform.dart';

/// Extra data a feature owns that "Delete all data" must also remove (for
/// example downloaded model files and their records, MCP server configs).
/// Features register one through [dataEraseHooksProvider]; each runs once,
/// after chats and providers are gone and before secrets are wiped.
typedef DataEraseHook = Future<void> Function();

/// Override to add feature-owned data to "Delete all data". Empty by
/// default: chats, providers, preferences and secrets are covered below.
final dataEraseHooksProvider = Provider<List<DataEraseHook>>((ref) => const []);

/// What [DataEraser.eraseAll] removed, for the confirmation message.
@immutable
final class EraseReport {
  const EraseReport({required this.sessions, required this.providers, required this.secrets});

  final int sessions;
  final int providers;
  final int secrets;
}

/// "Delete all data": every chat (messages, overlays, plans, checkpoints,
/// audit — the stores cascade per session), every provider with its keys,
/// feature data through [hooks], all other secrets, and preferences, which
/// sends the app back to onboarding.
///
/// Kept: the database key. Without it the (now empty) encrypted database
/// could not be opened at the next launch; with nothing left in it, the
/// key protects nothing of the user's. Old keys of quarantined databases
/// (`<key>.unreadable-*`) are deleted, which makes those files unreadable
/// for good: that is the point of deleting everything.
final class DataEraser {
  DataEraser({
    required this.sessions,
    required this.providers,
    required this.preferences,
    required this.secrets,
    this.ui,
    this.platform,
    this.hooks = const [],
  });

  final SessionStore sessions;
  final ProviderRegistry providers;
  final PreferencesStore preferences;
  final SecretStore secrets;
  final UiPreferencesStore? ui;
  final HandoffPlatform? platform;
  final List<DataEraseHook> hooks;

  Future<EraseReport> eraseAll() async {
    var sessionCount = await _deleteSessions();
    final providerIds = [for (final c in providers.configs) c.id];
    for (final id in providerIds) {
      await providers.remove(id);
    }
    for (final hook in hooks) {
      await hook();
    }
    var secretCount = 0;
    for (final key in await secrets.keys()) {
      if (key == databaseKeySecretName) continue;
      await secrets.delete(key);
      secretCount++;
    }
    await preferences.setDefaultModel(null);
    await ui?.save(const UiSettings());
    try {
      await platform?.clearShared();
    } on Object {
      // Temp files; the OS clears its cache directory too.
    }
    // A run that was mid-write can re-create its session (read before the
    // delete, written after). A second pass catches it.
    sessionCount += await _deleteSessions();
    // Last, so an interrupted erase leaves a working app the user can
    // retry from, rather than onboarding over half-deleted data.
    await preferences.setOnboardingComplete(false);
    return EraseReport(sessions: sessionCount, providers: providerIds.length, secrets: secretCount);
  }

  Future<int> _deleteSessions() async {
    final all = await sessions.listSessions(includeArchived: true);
    for (final s in all) {
      await sessions.deleteSession(s.id);
    }
    return all.length;
  }
}

final dataEraserProvider = Provider<DataEraser>(
  (ref) => DataEraser(
    sessions: ref.watch(sessionStoreProvider),
    providers: ref.watch(providerRegistryProvider),
    preferences: ref.watch(preferencesProvider),
    secrets: ref.watch(secretStoreProvider),
    ui: ref.watch(uiPreferencesStoreProvider),
    platform: ref.watch(handoffPlatformProvider),
    hooks: ref.watch(dataEraseHooksProvider),
  ),
);

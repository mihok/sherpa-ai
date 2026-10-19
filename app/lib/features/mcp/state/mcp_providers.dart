import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../../services/mcp/auth/mcp_oauth.dart';
import '../../../services/mcp/composer_sources.dart';
import '../../../services/mcp/mcp_records.dart';
import '../../../services/mcp/mcp_runtime.dart';
import '../../../services/mcp/registry_client.dart';
import '../../../services/mcp/server_probe.dart';

// ---------------------------------------------------------------------------
// Roots the integrator overrides in bootstrap() — see mcp_bootstrap.dart.
// ---------------------------------------------------------------------------

/// The app's MCP host (servers, router, hygiene, approvals, OAuth).
final mcpRuntimeProvider = Provider<McpRuntime>(
  (ref) => throw UnimplementedError('mcpRuntimeProvider must be overridden (see mcpFeatureOverrides)'),
);

/// HTTP client for the registry and server probes.
final mcpHttpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// Seams for tests: URL validation (DNS), probing, the registry.
final mcpUrlValidatorProvider = Provider<McpUrlValidator>((ref) => McpUrlValidator());

final mcpProberProvider = Provider<McpServerProber>((ref) => ConnectingMcpProber(client: ref.watch(mcpHttpClientProvider)));

final mcpRegistryClientProvider = Provider<McpRegistryClient>((ref) => McpRegistryClient(client: ref.watch(mcpHttpClientProvider)));

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

/// Counts runtime changes; everything below re-reads the runtime on a bump.
final mcpRevisionProvider = StreamProvider<int>((ref) async* {
  final rt = ref.watch(mcpRuntimeProvider);
  var n = 0;
  yield n;
  await for (final _ in rt.changes) {
    yield ++n;
  }
});

/// Waits until the start-up tool listing has finished (or timed out).
/// The chat must await it before `AgentRunner.resume`: a resumed run looks
/// its interrupted calls up synchronously, so a tool of a server that has
/// not been listed yet would read as "unknown". Completes at once when MCP
/// is not wired (tests).
final toolsReadyProvider = Provider<Future<void> Function()>((ref) => () async {});

/// How a server looks in the list.
enum McpServerDisplayStatus { connected, connecting, notConnected, needsAuth, offline, error, disabled }

/// One server, as the list and the detail screen show it.
final class McpServerView {
  McpServerView({
    required this.config,
    required this.health,
    required this.builtIn,
    required this.meta,
    required this.tools,
    required this.auth,
    required this.refreshError,
  });

  factory McpServerView.of(McpRuntime rt, McpServerConfig c) => McpServerView(
        config: c,
        health: rt.manager.health(c.id),
        builtIn: rt.isBuiltIn(c.id),
        meta: rt.metaOf(c.id),
        tools: rt.toolsOf(c.id),
        auth: rt.oauth.stateOf(c.id),
        refreshError: rt.router.refreshErrorFor(c.id),
      );

  final McpServerConfig config;
  final McpServerHealth health;
  final bool builtIn;
  final McpServerMeta? meta;
  final List<McpCatalogEntry> tools;
  final McpAuthState auth;
  final Object? refreshError;

  String get id => config.id;

  String get name => config.name;

  /// Host (and port) for display; built-ins say where they run.
  String get hostLabel => builtIn ? 'On this phone' : (config.url.hasPort ? '${config.url.host}:${config.url.port}' : config.url.host);

  int get pendingReviews => tools.where((t) => t.quarantined).length;

  int get flaggedTools => tools.where((t) => t.flagged).length;

  McpServerDisplayStatus get status => switch (health.status) {
        _ when !config.enabled => McpServerDisplayStatus.disabled,
        McpServerStatus.disabled => McpServerDisplayStatus.disabled,
        McpServerStatus.idle => McpServerDisplayStatus.notConnected,
        McpServerStatus.connecting => McpServerDisplayStatus.connecting,
        McpServerStatus.connected => McpServerDisplayStatus.connected,
        McpServerStatus.needsAuth => McpServerDisplayStatus.needsAuth,
        McpServerStatus.offline => McpServerDisplayStatus.offline,
        McpServerStatus.error => McpServerDisplayStatus.error,
      };

  /// The last problem in plain language, if there is one to show.
  String? get problem {
    if (!config.enabled) return null;
    final auth = this.auth.failure;
    if (auth != null) return auth;
    if (status == McpServerDisplayStatus.needsAuth) {
      return this.auth.consent?.purpose == null ? 'Sign in to use this server.' : _authLine;
    }
    if (status == McpServerDisplayStatus.connected) return null;
    final e = health.lastError;
    if (e == null || e.isEmpty) return null;
    return describeLastError(e);
  }

  String get _authLine => switch (auth.consent!.purpose.name) {
        'stepUp' => 'The server asks for more permissions.',
        'reauthorize' => 'The sign-in expired. Sign in again.',
        _ => 'Sign in to use this server.',
      };
}

final mcpServersProvider = Provider<List<McpServerView>>((ref) {
  ref.watch(mcpRevisionProvider);
  final rt = ref.watch(mcpRuntimeProvider);
  return [for (final c in rt.servers) McpServerView.of(rt, c)];
});

final mcpServerProvider = Provider.family<McpServerView?, String>((ref, id) {
  ref.watch(mcpRevisionProvider);
  final rt = ref.watch(mcpRuntimeProvider);
  final c = rt.server(id);
  return c == null ? null : McpServerView.of(rt, c);
});

/// Every tool waiting for review, with its server's name.
final mcpPendingReviewsProvider = Provider<List<(ToolReview, String)>>((ref) {
  ref.watch(mcpRevisionProvider);
  final rt = ref.watch(mcpRuntimeProvider);
  return [for (final r in rt.pendingReviews) (r, rt.server(r.key.serverId)?.name ?? r.key.serverId)];
});

/// The current review of one tool.
final mcpToolReviewProvider = Provider.family<ToolReview?, McpToolKey>((ref, key) {
  ref.watch(mcpRevisionProvider);
  return ref.watch(mcpRuntimeProvider).hygiene.reviewOf(key);
});

/// Remembered approvals, newest first.
final mcpGrantsProvider = Provider<List<ApprovalGrant>>((ref) {
  ref.watch(mcpRevisionProvider);
  final grants = ref.watch(mcpRuntimeProvider).policy.grants.toList()..sort((a, b) => b.grantedAt.compareTo(a.grantedAt));
  return grants;
});

/// Whether Sherpa holds OAuth tokens for a server.
final mcpHasCredentialsProvider = FutureProvider.autoDispose.family<bool, String>((ref, id) {
  ref.watch(mcpRevisionProvider);
  return ref.watch(mcpRuntimeProvider).oauth.hasCredentials(id);
});

// ---------------------------------------------------------------------------
// Per-session tools
// ---------------------------------------------------------------------------

/// One tool row of the session sheet.
final class SessionToolRow {
  const SessionToolRow({required this.entry, required this.enabled, required this.globallyEnabled});

  final McpCatalogEntry entry;

  /// On for this session (session override, else the global switch).
  final bool enabled;
  final bool globallyEnabled;

  String get name => entry.modelName;

  String get label => entry.tool.displayName;
}

/// One server group of the session sheet.
final class SessionServerTools {
  const SessionServerTools({required this.server, required this.enabled, required this.tools});

  final McpServerView server;

  /// The server is on for this session.
  final bool enabled;
  final List<SessionToolRow> tools;
}

/// The servers and tools a session may use. Servers the user turned off
/// in settings are not listed (they are off everywhere); quarantined tools
/// are not listed (they cannot run until reviewed).
final sessionToolsProvider = Provider.family<List<SessionServerTools>, String>((ref, sessionId) {
  final servers = ref.watch(mcpServersProvider);
  final rt = ref.watch(mcpRuntimeProvider);
  final e = rt.enablement;
  return [
    for (final s in servers)
      if (s.config.enabled)
        SessionServerTools(
          server: s,
          enabled: e.isServerEnabled(sessionId, s.id),
          tools: [
            for (final t in s.tools)
              if (!t.quarantined && t.tool.modelVisible)
                SessionToolRow(
                  entry: t,
                  enabled: e.isToolEnabled(sessionId, t.modelName),
                  globallyEnabled: e.isToolEnabledGlobally(t.modelName),
                ),
          ],
        ),
  ];
});

/// Switches for [sessionId] only (the sheet in the chat).
final class SessionToolSwitches {
  SessionToolSwitches(this._rt, this.sessionId);

  final McpRuntime _rt;
  final String sessionId;

  Future<void> setServer(String serverId, bool enabled) =>
      _rt.enablement.setServerEnabled(serverId, enabled, sessionId: sessionId);

  Future<void> setTool(String toolName, bool enabled) =>
      _rt.enablement.setToolEnabled(toolName, enabled, sessionId: sessionId);

  /// Back to the global switches for every server and tool.
  Future<void> reset() => _rt.enablement.forgetSession(sessionId);
}

final sessionToolSwitchesProvider = Provider.family<SessionToolSwitches, String>(
  (ref, sessionId) => SessionToolSwitches(ref.watch(mcpRuntimeProvider), sessionId),
);

// ---------------------------------------------------------------------------
// Composer: slash commands from prompts, @ mentions of resources
// ---------------------------------------------------------------------------

final mcpComposerSourcesProvider = Provider<McpComposerSources>((ref) => McpComposerSources(ref.watch(mcpRuntimeProvider)));

/// Slash commands from the prompts of the servers enabled for a session
/// (null: every enabled server). Invalidate to re-list.
final mcpPromptCommandsProvider = FutureProvider.autoDispose.family<List<McpPromptCommand>, String?>(
  (ref, sessionId) => ref.watch(mcpComposerSourcesProvider).promptCommands(sessionId: sessionId),
);

/// `@` suggestions for what the user typed after `@`.
typedef McpMentionQuery = ({String? sessionId, String query});

final mcpResourceSuggestionsProvider = FutureProvider.autoDispose.family<List<McpResourceSuggestion>, McpMentionQuery>(
  (ref, q) => ref.watch(mcpComposerSourcesProvider).resourceSuggestions(q.query, sessionId: q.sessionId),
);

/// What the chat calls at a user-turn boundary, before sending a new user
/// message (send, edit, regenerate): starts a new tool segment when the
/// session's frozen tool list went stale (see [McpRuntime.onUserTurn]).
/// A no-op when MCP is not wired (tests).
final toolsUserTurnHookProvider = Provider<void Function(String sessionId)>((ref) => (_) {});

/// The source label for the add screen.
McpServerSource sourceFromName(String? name) =>
    McpServerSource.values.where((s) => s.name == name).firstOrNull ?? McpServerSource.url;

/// The MCP tool layer behind sherpa_core's [ToolRouter].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart'
    show
        CancelledException,
        Clock,
        HeuristicTokenCounter,
        JsonMap,
        SystemClock,
        TextPart,
        TokenCounter,
        ToolAnnotations,
        ToolCall,
        ToolDefinition,
        ResolvedToolCall,
        ToolExecutionContext,
        ToolResult,
        ToolRouter,
        ToolSelectionHints,
        ToolSource,
        ToolSourceKind;
import 'package:sherpa_net/sherpa_net.dart' show Redactor;

import '../config.dart';
import '../errors.dart';
import '../protocol/primitives.dart';
import 'bm25.dart';
import 'budget.dart';
import 'canonical.dart';
import 'enablement.dart';
import 'hygiene.dart';
import 'injection_scanner.dart';
import 'result_limits.dart';
import 'schema_normalizer.dart';
import 'server_manager.dart';
import 'tool_names.dart';

/// An optional semantic ranker for `tool_search` (e.g. an on-device
/// EmbeddingGemma); fused with BM25 by reciprocal rank (R11 §9.5 "hybrid
/// BM25 plus embeddings").
abstract interface class ToolEmbedder {
  /// One vector per text, same order.
  Future<List<List<double>>> embed(List<String> texts);
}

/// One tool in the router's catalog.
@immutable
final class McpCatalogEntry {
  const McpCatalogEntry({
    required this.key,
    required this.modelName,
    required this.tool,
    required this.server,
    required this.definition,
    required this.review,
  });

  final McpToolKey key;

  /// The namespaced model-facing name (`<server>__<tool>`).
  final String modelName;

  /// The tool as the server lists it now.
  final McpTool tool;
  final McpServerConfig server;

  /// What the agent loop sees: namespaced name, original schema, and the
  /// EFFECTIVE annotations — the server's hints only when the server is
  /// trusted and the tool approved and unflagged; otherwise the spec's
  /// untrusted defaults (destructive, open-world), so the approval policy
  /// never relaxes on a claim it may not trust (R01 §6.2 MUST).
  final ToolDefinition definition;
  final ToolReview review;

  bool get quarantined => review.quarantined;

  bool get flagged => review.flagged;

  /// Whether [definition] carries the server's own annotations.
  bool get annotationsTrusted => server.trusted && !review.quarantined && !review.flagged;
}

/// What the approval layer and the UI need to know about a tool's hygiene.
@immutable
final class ToolHygieneInfo {
  const ToolHygieneInfo({
    required this.key,
    required this.modelName,
    required this.status,
    required this.findings,
    required this.annotationsTrusted,
    required this.declaredAnnotations,
  });

  final McpToolKey key;
  final String modelName;
  final ToolReviewStatus status;
  final List<HygieneFinding> findings;

  /// False: the definition's annotations are the untrusted defaults; show
  /// [declaredAnnotations] as "the server says … (unverified)".
  final bool annotationsTrusted;
  final ToolAnnotations declaredAnnotations;

  bool get quarantined => status != ToolReviewStatus.approved;

  bool get flagged => findings.isNotEmpty;

  /// Calls need a human even where the policy would auto-approve.
  bool get requiresConfirmation => quarantined || flagged;
}

/// A tool call resolved to its real target (unwrapping `call_tool`), with
/// the router's own detail. [McpToolRouter.resolve] turns it into
/// sherpa_core's [ResolvedToolCall] for the agent loop.
@immutable
final class McpResolvedCall {
  const McpResolvedCall({
    required this.call,
    required this.known,
    this.definition,
    this.viaProxy = false,
    this.correctedName = false,
    this.refusal,
  });

  /// The call to run: for `call_tool`, the inner call (target name and
  /// arguments, same id).
  final ToolCall call;

  /// Whether this router owns the call at all.
  final bool known;

  /// The target's definition (null when unresolved).
  final ToolDefinition? definition;
  final bool viaProxy;

  /// The name had to be normalized or fuzzy-matched: a non-read-only target
  /// then always needs approval (R11 §9.6.7).
  final bool correctedName;

  /// Why the router will refuse to run it (model-facing), if it will.
  final String? refusal;
}

/// The persistable part of a session's tool state, so a restarted app
/// offers the same tool list again (prompt / KV caches stay warm).
@immutable
final class McpRouterSessionState {
  const McpRouterSessionState({
    required this.sessionId,
    this.deferred = false,
    this.segment = 0,
    this.visibleTools = const [],
    this.recentTools = const [],
  });

  factory McpRouterSessionState.fromJson(JsonMap j) => McpRouterSessionState(
        sessionId: j['sessionId']! as String,
        deferred: j['deferred'] == true,
        segment: (j['segment'] as num?)?.toInt() ?? 0,
        visibleTools: [...((j['visibleTools'] as List?) ?? const []).whereType<String>()],
        recentTools: [...((j['recentTools'] as List?) ?? const []).whereType<String>()],
      );

  final String sessionId;
  final bool deferred;
  final int segment;

  /// Model-facing names of the current segment's tools, in order.
  final List<String> visibleTools;

  /// Most recently used first.
  final List<String> recentTools;

  JsonMap toJson() => {
        'sessionId': sessionId,
        'deferred': deferred,
        'segment': segment,
        'visibleTools': visibleTools,
        'recentTools': recentTools,
      };
}

final class _Snapshot {
  _Snapshot(this.tools, this.fetchedAt, this.review);

  final List<McpTool> tools;
  final DateTime fetchedAt;
  final ToolListReview review;
  bool dirty = false;
}

final class _Segment {
  _Segment(this.tools, {required this.deferred, required this.number});

  final List<ToolDefinition> tools;
  final bool deferred;
  final int number;

  Iterable<String> get names => tools.map((t) => t.name);
}

final class _Session {
  _Session(this.id);

  final String id;
  bool deferred = false;
  int segmentNumber = 0;
  _Segment? segment;
  Future<List<ToolDefinition>>? pending;
  final List<String> recent = [];
  List<String>? restoredVisible;

  /// `ToolBudget.forModel` from the last [ToolSelectionHints].
  ToolBudget? hinted;
}

/// Aggregates the tools of every enabled MCP server (remote and on-device)
/// behind sherpa_core's [ToolRouter].
///
/// **Naming.** Tools are offered as `<server>__<tool>` ([McpToolNamer]):
/// collision-free across servers, provider-safe and stable across sessions.
///
/// **Visibility and hygiene.** Tools whose MCP Apps visibility lacks
/// `"model"` are never offered or model-callable (R03 §3) but [lookup]
/// and [executeForApp] still find them. Every `tools/list` goes through
/// [ToolHygiene]: quarantined tools (new from an untrusted server, or
/// changed anywhere) are neither offered nor executable until approved.
///
/// **Budget and segments.** The tool list is part of the prompt prefix:
/// changing it mid-conversation breaks prompt / KV caches and makes
/// append-only providers (Anthropic, with replayed thinking) reject the
/// request (PLAN "Context segments"). So the first [toolsForTurn] of a
/// segment decides the session's list and every later call returns exactly
/// the same definitions until the caller starts a new segment
/// ([resetSegment]) at a user-turn boundary. When the eligible tools exceed
/// the session's [ToolBudget] (count or schema tokens), the session switches
/// to DEFERRED mode for good: a small stable core (user-pinned, [alwaysOn],
/// sticky recently used, and the best matches for the turn's query) plus
/// two proxies, `tool_search` (BM25 [+ embeddings] over names, descriptions
/// and parameter names; compact cards) and `call_tool` (dispatch to any
/// enabled tool), so the long tail stays reachable without the list ever
/// changing (R11 §9.5).
///
/// **Execution.** Arguments are validated against the ORIGINAL schema with
/// safe coercions (the model may have seen a normalized one), calls carry
/// the loop's idempotency key (`ToolExecutionContext.idempotencyKey`,
/// `<assistantMessageId>:<callId>`, stable across resume; R11 §9.8), results
/// are size-limited, and every failure becomes a model-friendly, redacted
/// [ToolResult.error]; only cancellation throws.
///
/// **Approvals.** The agent loop calls [resolve] before gating: a
/// `call_tool` call is decided, audited and shown to the user as its
/// TARGET (a refusal is answered without asking, a corrected name forces a
/// one-off confirmation), so nothing is ever granted to the proxy.
/// `call_tool` stays declared destructive/open-world for any caller that
/// does not resolve. `McpApprovalHandler` is no longer needed with
/// `AgentRunner` (it passes resolved calls straight through).
///
/// **Budget.** Without [setBudget] or an explicit constructor
/// `defaultBudget`, a session's budget follows the model the loop describes
/// ([ToolSelectionHints]: `ToolBudget.forModel`).
final class McpToolRouter implements ToolRouter {
  McpToolRouter({
    required this.manager,
    ToolHygiene? hygiene,
    this.enablement = const AllToolsEnabled(),
    TokenCounter? counter,
    ToolBudget? defaultBudget,
    String Function(McpServerConfig config)? namespaceFor,
    Set<String> alwaysOn = const {},
    this.embedder,
    Clock clock = const SystemClock(),
    this.refreshTimeout = const Duration(seconds: 5),
    this.maxCatalogAge = const Duration(minutes: 1),
    this.validateArgs = true,
    this.onGrantsInvalidated,
  })  : hygiene = hygiene ?? ToolHygiene(clock: clock),
        defaultBudget = defaultBudget ?? ToolBudget.remote,
        _explicitDefaultBudget = defaultBudget,
        _counter = counter ?? HeuristicTokenCounter(),
        _namespaceFor = namespaceFor,
        _alwaysOn = {...alwaysOn},
        _clock = clock {
    _managerSub = manager.events.listen(_onManagerEvent);
    _hygieneSub = this.hygiene.changes.listen((_) => _rebuild());
    final previous = this.hygiene.onApproved;
    this.hygiene.onApproved = (key, {required wasChange}) {
      previous?.call(key, wasChange: wasChange);
      final name = _byKey[key]?.modelName;
      if (wasChange && name != null) onGrantsInvalidated?.call(name);
    };
  }

  static const String searchToolName = 'tool_search';
  static const String callToolName = 'call_tool';

  /// `ToolSource.serverId` of the two proxies. Not a real server: never
  /// trust it in an `ApprovalPolicy`.
  static const String proxyServerId = 'sherpa.tools';

  static const ToolSource _proxySource = ToolSource(ToolSourceKind.mcp, serverId: proxyServerId, serverName: 'Tool index');

  /// The search proxy. Read-only and closed-world (it only reads the local
  /// index), but its source is non-built-in on purpose: its output quotes
  /// untrusted server text, so it must taint the session (R11 §9.7). For
  /// approvals [resolve] presents it as built-in ([_searchGateDefinition]):
  /// it is Sherpa's own code, and the untrusted proxy source would
  /// otherwise make every search ask the user.
  static const ToolDefinition searchToolDefinition = ToolDefinition(
    name: searchToolName,
    title: 'Search tools',
    description: 'Find more tools by what they do. Returns matching tools with their exact names and parameters; '
        'then run one with call_tool.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'What you want to do, in a few words (or an exact tool name).'},
        'limit': {'type': 'integer', 'description': 'Maximum number of results (default 5).', 'minimum': 1, 'maximum': 10},
      },
      'required': ['query'],
      'additionalProperties': false,
    },
    annotations: ToolAnnotations(title: 'Search tools', readOnlyHint: true, idempotentHint: true, openWorldHint: false),
    source: _proxySource,
  );

  /// [searchToolDefinition] as the approval policy should judge it.
  static const ToolDefinition _searchGateDefinition = ToolDefinition(
    name: searchToolName,
    title: 'Search tools',
    description: 'Find more tools by what they do.',
    inputSchema: {'type': 'object'},
    annotations: ToolAnnotations(title: 'Search tools', readOnlyHint: true, idempotentHint: true, openWorldHint: false),
  );

  /// The dispatch proxy. Declared with the untrusted defaults (destructive,
  /// open-world, not idempotent): its effect is whatever the target does, so
  /// the loop must always consult the approval handler, must not re-run it
  /// on resume, and must treat its output as untrusted.
  static const ToolDefinition callToolDefinition = ToolDefinition(
    name: callToolName,
    title: 'Call a tool',
    description: 'Run a tool found with tool_search: pass its exact name and its arguments.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'The exact tool name from tool_search.'},
        // additionalProperties must be explicit: llama.cpp's grammar
        // converter defaults it to false, which would force `{}`.
        'arguments': {
          'type': 'object',
          'description': "The tool's arguments as an object.",
          'additionalProperties': true,
        },
      },
      'required': ['name'],
      'additionalProperties': false,
    },
    annotations: ToolAnnotations(title: 'Call a tool'),
    source: _proxySource,
  );

  final McpServerManager manager;
  final ToolHygiene hygiene;
  final ToolEnablement enablement;

  /// The budget of sessions without [setBudget] when the agent loop gives
  /// no [ToolSelectionHints] (remote, unless the constructor was given one;
  /// a budget given to the constructor also wins over the hints).
  final ToolBudget defaultBudget;
  final ToolBudget? _explicitDefaultBudget;
  final ToolEmbedder? embedder;

  /// How long [toolsForTurn] waits for servers to list their tools; slower
  /// servers keep loading in the background and appear in later segments
  /// (and in `tool_search` as soon as they land).
  final Duration refreshTimeout;

  /// Lists older than this are re-fetched at the next segment start (the
  /// connection's own `ttlMs` cache may still answer without a round trip).
  final Duration maxCatalogAge;

  /// Validate (and safely coerce) arguments before sending them.
  final bool validateArgs;

  /// A changed tool was re-approved: its old "always" grants were for the
  /// old definition. Wire to `ApprovalPolicy.revoke` (R11 §9.7: grants are
  /// for a server + tool + hash). Definitions carry `definitionHash`, so
  /// stale grants no longer match anyway; this also drops them from the
  /// user's list of grants.
  final void Function(String modelName)? onGrantsInvalidated;

  final TokenCounter _counter;
  final String Function(McpServerConfig config)? _namespaceFor;
  final Set<String> _alwaysOn;
  final Clock _clock;
  late final StreamSubscription<McpServerEvent> _managerSub;
  late final StreamSubscription<ToolListReview> _hygieneSub;

  final Map<String, _Snapshot> _snapshots = {};
  final Map<String, Future<void>> _refreshing = {};
  final Set<String> _rerun = {};
  final Map<String, Object> _refreshErrors = {};
  List<McpCatalogEntry> _catalog = const [];
  Map<String, McpCatalogEntry> _byName = const {};
  Map<McpToolKey, McpCatalogEntry> _byKey = const {};
  Bm25Index? _index;
  int _revision = 0;
  final Map<String, ToolBudget> _budgets = {};
  final Map<String, _Session> _sessions = {};
  final Map<String, JsonMap> _normalized = {};
  final Map<String, List<double>> _embeddings = {};
  bool _disposed = false;

  // ---------------------------------------------------------------- catalog

  /// Every known tool (all servers with a fetched list, quarantined ones
  /// included), in server order then server listing order.
  List<McpCatalogEntry> get catalog => _catalog;

  /// Increments whenever the catalog changes.
  int get revision => _revision;

  McpCatalogEntry? entryFor(String modelName) => _byName[modelName];

  McpCatalogEntry? entryForKey(McpToolKey key) => _byKey[key];

  /// The last failure listing a server's tools, if its last attempt failed.
  Object? refreshErrorFor(String serverId) => _refreshErrors[serverId];

  /// Hygiene facts for the approval sheet / tool settings.
  ToolHygieneInfo? hygieneFor(String modelName) {
    final e = _byName[modelName];
    if (e == null) return null;
    return ToolHygieneInfo(
      key: e.key,
      modelName: e.modelName,
      status: e.review.status,
      findings: e.review.findings,
      annotationsTrusted: e.annotationsTrusted,
      declaredAnnotations: e.tool.annotations,
    );
  }

  /// Injection findings in a server's `instructions` (system-prompt
  /// material the app may show or include).
  List<HygieneFinding> instructionFindings(String serverId) {
    final text = manager.connectedOrNull(serverId)?.instructions;
    return text == null ? const [] : hygiene.scanner.scanText(text, location: 'instructions');
  }

  /// Approves a quarantined tool by model name (see [ToolHygiene.approve]).
  Future<bool> approve(String modelName) async {
    final e = _byName[modelName];
    return e != null && await hygiene.approve(e.key);
  }

  /// Re-lists every enabled server's tools (all at once) and re-reviews
  /// them. [force] bypasses the connections' `ttlMs` caches.
  Future<void> refresh({bool force = false}) async {
    await Future.wait([
      for (final c in manager.servers)
        if (c.enabled) _refreshServer(c.id, force: force),
    ]);
  }

  /// One refresh per server at a time. A forced request that arrives while
  /// one runs (a `list_changed` during a fetch that may already hold the old
  /// list) makes it run once more afterwards, so no change is lost.
  Future<void> _refreshServer(String id, {bool force = false}) {
    final running = _refreshing[id];
    if (running != null) {
      if (force) _rerun.add(id);
      return running;
    }
    Future<void> loop() async {
      var forced = force;
      do {
        _rerun.remove(id);
        await _doRefresh(id, force: forced);
        forced = true;
      } while (_rerun.contains(id) && !_disposed);
    }

    final f = loop();
    _refreshing[id] = f;
    return f.whenComplete(() => _refreshing.remove(id));
  }

  Future<void> _doRefresh(String id, {required bool force}) async {
    try {
      final tools = await manager.listTools(id, refresh: force);
      final config = manager.config(id);
      if (config == null || _disposed) return;
      final review = await hygiene.review(config, tools, otherToolNames: _otherToolNames(id));
      _snapshots[id] = _Snapshot(tools, _clock.now(), review);
      _refreshErrors.remove(id);
      _rebuild();
    } on Object catch (e) {
      // Keep the last good list; the server's tools stay known (calls fail
      // fast while it is offline) and the next segment retries.
      _refreshErrors[id] = e;
      _snapshots[id]?.dirty = true;
    }
  }

  List<String> _otherToolNames(String serverId) => [
        for (final e in _catalog)
          if (e.server.id != serverId) ...[e.modelName, e.tool.name],
      ];

  void _onManagerEvent(McpServerEvent e) {
    if (_disposed) return;
    switch (e) {
      case McpServerToolsChanged(:final serverId):
        _snapshots[serverId]?.dirty = true;
        // Re-list now: a rug pull should be quarantined before the next call.
        unawaited(_refreshServer(serverId, force: true));
      case McpServerConfigUpdated():
        _rebuild(); // trust / enablement changes the effective definitions
      case McpServerRemoved(:final serverId):
        _snapshots.remove(serverId);
        unawaited(hygiene.forgetServer(serverId).then((_) => _rebuild()));
      case McpServerStatusChanged():
        break;
    }
  }

  void _rebuild() {
    if (_disposed) return;
    final servers = manager.servers;
    final namespaces = <String, String>{
      for (final c in servers) c.id: McpToolNamer.namespace(_namespaceFor?.call(c) ?? c.id),
    };
    final keys = <McpToolKey, String>{
      for (final c in servers)
        if (_snapshots[c.id] case final snap?)
          for (final t in snap.tools) McpToolKey(c.id, t.name): namespaces[c.id]!,
    };
    final names = McpToolNamer.assign(keys);
    final entries = <McpCatalogEntry>[];
    for (final c in servers) {
      final snap = _snapshots[c.id];
      if (snap == null) continue;
      for (final t in snap.tools) {
        final key = McpToolKey(c.id, t.name);
        final review = hygiene.reviewOf(key) ?? snap.review.reviews.firstWhere((r) => r.key == key);
        final name = names[key]!;
        entries.add(McpCatalogEntry(
          key: key,
          modelName: name,
          tool: t,
          server: c,
          definition: _definitionFor(t, c, name, review),
          review: review,
        ));
      }
    }
    _catalog = List.unmodifiable(entries);
    _byName = {for (final e in entries) e.modelName: e};
    _byKey = {for (final e in entries) e.key: e};
    _index = null;
    _revision++;
  }

  static ToolDefinition _definitionFor(McpTool t, McpServerConfig c, String name, ToolReview review) {
    final trusted = c.trusted && !review.quarantined && !review.flagged;
    return ToolDefinition(
      name: name,
      originalName: t.name,
      title: t.title,
      description: t.description ?? '',
      inputSchema: t.inputSchema,
      outputSchema: t.outputSchema,
      annotations: trusted ? t.annotations : ToolAnnotations(title: t.annotations.title),
      source: ToolSource(
        c.transport == McpTransportPreference.inProcess ? ToolSourceKind.onDevice : ToolSourceKind.mcp,
        serverId: c.id,
        serverName: c.name,
      ),
      uiResourceUri: t.uiResourceUri,
      modelVisible: t.modelVisible,
      // Flagged or not yet approved: the policy asks even where it would
      // auto-approve.
      requiresConfirmation: review.quarantined || review.flagged,
      // Grants are bound to the reviewed definition (R11 §9.7: "always" is
      // per server + tool + hash), so a changed tool needs a new grant.
      definitionHash: review.currentHash,
    );
  }

  // ---------------------------------------------------------------- budgets & sessions

  /// The budget of [sessionId]: [setBudget], else an explicit constructor
  /// `defaultBudget`, else the profile for the model the agent loop
  /// described at the session's last segment start, else [defaultBudget].
  ToolBudget budgetFor(String sessionId) =>
      _budgets[sessionId] ?? _explicitDefaultBudget ?? _sessions[sessionId]?.hinted ?? defaultBudget;

  /// Sets a session's budget. Takes effect at its next segment (switching
  /// models is a segment boundary: call [resetSegment] too).
  void setBudget(String sessionId, ToolBudget? budget) {
    if (budget == null) {
      _budgets.remove(sessionId);
    } else {
      _budgets[sessionId] = budget;
    }
  }

  _Session _session(String id) => _sessions.putIfAbsent(id, () => _Session(id));

  /// Whether the session is in deferred (search / call proxy) mode.
  bool isDeferred(String sessionId) => _sessions[sessionId]?.deferred ?? false;

  /// Segment counter (1 after the first [toolsForTurn]).
  int segmentOf(String sessionId) => _sessions[sessionId]?.segmentNumber ?? 0;

  /// Ends the session's segment: the next [toolsForTurn] recomputes the
  /// list (picking up enablement changes, approvals, new servers, sticky
  /// tools). Call only at a user-turn boundary. A deferred session stays
  /// deferred unless [reevaluateMode] is set (avoids flapping between two
  /// very different tool lists).
  void resetSegment(String sessionId, {bool reevaluateMode = false}) {
    final s = _sessions[sessionId];
    if (s == null) return;
    s.segment = null;
    s.restoredVisible = null;
    if (reevaluateMode) s.deferred = false;
  }

  /// Whether what the session sees no longer matches what a new segment
  /// would offer (a frozen tool became unusable, or — in direct mode — the
  /// eligible set or a definition changed). The app may then call
  /// [resetSegment] at the next user turn. Execution always checks the
  /// live state, so a stale segment is never a security problem.
  bool isSegmentStale(String sessionId) {
    final s = _sessions[sessionId];
    final seg = s?.segment;
    if (s == null || seg == null) return false;
    final budget = budgetFor(sessionId);
    for (final t in seg.tools) {
      if (t.name == searchToolName || t.name == callToolName) continue;
      final e = _byName[t.name];
      if (e == null || _refusal(e, sessionId, forModel: true) != null) return true;
      if (_promptForm(_render(e, budget)) != _promptForm(t)) return true;
    }
    if (!seg.deferred) {
      final eligible = {for (final e in _catalog) if (_eligible(e, sessionId)) e.modelName};
      return !eligible.containsAll(seg.names) || !seg.names.toSet().containsAll(eligible);
    }
    final core = seg.names.toSet();
    return _catalog.any(
        (e) => _eligible(e, sessionId) && enablement.isPinned(sessionId, e.modelName) && !core.contains(e.modelName));
  }

  /// What providers actually send for a tool (annotations and source are
  /// local metadata: a trust change does not touch the prompt prefix).
  static String _promptForm(ToolDefinition t) =>
      canonicalJson({'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema});

  /// Most recently used tools of a session, newest first.
  List<String> recentTools(String sessionId) => List.unmodifiable(_sessions[sessionId]?.recent ?? const <String>[]);

  McpRouterSessionState exportSession(String sessionId) {
    final s = _sessions[sessionId];
    return McpRouterSessionState(
      sessionId: sessionId,
      deferred: s?.deferred ?? false,
      segment: s?.segmentNumber ?? 0,
      visibleTools: [...?s?.segment?.names],
      recentTools: [...?s?.recent],
    );
  }

  /// Restores [exportSession] output after a restart: the next
  /// [toolsForTurn] rebuilds the saved list (minus tools that are gone or
  /// no longer usable) instead of choosing anew.
  void importSession(McpRouterSessionState state) {
    final s = _session(state.sessionId)
      ..deferred = state.deferred
      ..segmentNumber = state.segment
      ..segment = null
      ..restoredVisible = state.visibleTools.isEmpty ? null : [...state.visibleTools];
    s.recent
      ..clear()
      ..addAll(state.recentTools.take(_maxRecent));
  }

  void forgetSession(String sessionId) {
    _sessions.remove(sessionId);
    _budgets.remove(sessionId);
  }

  static const int _maxRecent = 16;

  void _touch(String sessionId, String name) {
    final r = _session(sessionId).recent
      ..remove(name)
      ..insert(0, name);
    if (r.length > _maxRecent) r.removeRange(_maxRecent, r.length);
  }

  bool _eligible(McpCatalogEntry e, String sessionId) =>
      !e.quarantined &&
      e.tool.modelVisible &&
      (manager.config(e.server.id)?.enabled ?? false) &&
      enablement.isServerEnabled(sessionId, e.server.id) &&
      enablement.isToolEnabled(sessionId, e.modelName);

  /// The definition as offered to a session's model: normalized schema and
  /// trimmed description for local models (R11 §9.6.5), the original for
  /// remote ones.
  ToolDefinition _render(McpCatalogEntry e, ToolBudget budget) {
    if (!budget.normalizeSchemas) return e.definition;
    final o = budget.normalization;
    final cacheKey = '${e.review.currentHash}:${o.maxParamDescription}:${o.maxEnumValues}:${o.maxDepth}:${o.maxRefDepth}';
    final schema = _normalized.putIfAbsent(cacheKey, () => SchemaNormalizer.normalize(e.definition.inputSchema, options: o));
    return e.definition.copyWith(
      inputSchema: schema,
      description: SchemaNormalizer.trimDescription(e.definition.description, max: o.maxToolDescription),
    );
  }

  // ---------------------------------------------------------------- ToolRouter

  @override
  Future<List<ToolDefinition>> toolsForTurn({
    required String sessionId,
    String? query,
    int? schemaTokenBudget,
    ToolSelectionHints? hints,
  }) async {
    final s = _session(sessionId);
    final seg = s.segment;
    if (seg != null) return List.of(seg.tools);
    final pending = s.pending;
    if (pending != null) return List.of(await pending);
    // Budgets change only at a segment start, like [setBudget].
    if (hints != null) {
      s.hinted = ToolBudget.forModel(
        onDevice: hints.onDevice,
        parameterBillions: hints.parameterBillions,
        reservedSlots: hints.reservedTools,
      );
    }
    final f = _startSegment(s, query, schemaTokenBudget);
    s.pending = f;
    try {
      return List.of(await f);
    } finally {
      s.pending = null;
    }
  }

  Future<List<ToolDefinition>> _startSegment(_Session s, String? query, int? schemaTokenBudget) async {
    await _ensureFresh();
    final budget = budgetFor(s.id);
    final tokenBudget = math.min(budget.maxSchemaTokens, schemaTokenBudget ?? budget.maxSchemaTokens);
    final eligible = [for (final e in _catalog) if (_eligible(e, s.id)) e];
    final rendered = {for (final e in eligible) e.modelName: _render(e, budget)};

    final List<ToolDefinition> tools;
    final restored = s.restoredVisible;
    if (restored != null) {
      s.restoredVisible = null;
      tools = [
        for (final n in restored)
          if (n == searchToolName)
            searchToolDefinition
          else if (n == callToolName)
            callToolDefinition
          else
            ?rendered[n],
      ];
    } else {
      final total = _counter.countTools(rendered.values.toList());
      if (!s.deferred && (eligible.length > budget.slots || total > tokenBudget)) s.deferred = true;
      if (!s.deferred) {
        tools = [for (final e in eligible) rendered[e.modelName]!];
      } else {
        final core = await _chooseCore(s, eligible, rendered, budget, tokenBudget, query);
        tools = [...core, searchToolDefinition, callToolDefinition];
      }
    }
    final seg = _Segment(List.unmodifiable(tools), deferred: s.deferred, number: ++s.segmentNumber);
    s.segment = seg;
    return seg.tools;
  }

  /// The deferred core: pinned → always-on → sticky recent → query matches,
  /// within the core slots and the schema-token budget, in catalog order.
  Future<List<ToolDefinition>> _chooseCore(
    _Session s,
    List<McpCatalogEntry> eligible,
    Map<String, ToolDefinition> rendered,
    ToolBudget budget,
    int tokenBudget,
    String? query,
  ) async {
    var tokensLeft = tokenBudget - _counter.countTools(const [searchToolDefinition, callToolDefinition]);
    final picked = <String>{};
    bool add(String name) {
      if (picked.length >= budget.coreSlots || picked.contains(name)) return false;
      final d = rendered[name];
      if (d == null) return false;
      final cost = _counter.countTools([d]);
      if (cost > tokensLeft) return false;
      tokensLeft -= cost;
      picked.add(name);
      return true;
    }

    for (final e in eligible) {
      if (enablement.isPinned(s.id, e.modelName)) add(e.modelName);
    }
    for (final e in eligible) {
      if (_alwaysOn.contains(e.modelName)) add(e.modelName);
    }
    var sticky = 0;
    for (final name in s.recent) {
      if (sticky >= budget.stickyTools) break;
      if (add(name)) sticky++;
    }
    final q = query?.trim();
    if (q != null && q.isNotEmpty && budget.queryTools > 0) {
      final allowed = rendered.keys.toSet();
      var added = 0;
      for (final name in await _rank(q, allowed, budget.queryTools + picked.length)) {
        if (added >= budget.queryTools) break;
        if (add(name)) added++;
      }
    }
    return [for (final e in eligible) if (picked.contains(e.modelName)) rendered[e.modelName]!];
  }

  /// Refreshes stale or never-listed servers, waiting at most
  /// [refreshTimeout]. Servers known to be down keep their last list.
  Future<void> _ensureFresh() async {
    final now = _clock.now();
    final work = <Future<void>>[];
    for (final c in manager.servers) {
      if (!c.enabled) continue;
      final snap = _snapshots[c.id];
      final stale = snap == null || snap.dirty || now.difference(snap.fetchedAt) > maxCatalogAge;
      if (!stale) continue;
      final status = manager.health(c.id).status;
      final down = status == McpServerStatus.offline ||
          status == McpServerStatus.needsAuth ||
          status == McpServerStatus.error;
      if (snap != null && down) continue;
      work.add(_refreshServer(c.id));
    }
    if (work.isEmpty) return;
    final done = Completer<void>();
    final timer = Timer(refreshTimeout, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(Future.wait(work).whenComplete(() {
      if (!done.isCompleted) done.complete();
    }));
    await done.future;
    timer.cancel();
  }

  /// Synchronous, so it only knows servers already listed: call [refresh]
  /// once at start-up (before resuming interrupted runs, whose first step
  /// looks tools up before any [toolsForTurn]).
  @override
  ToolDefinition? lookup(String name) {
    if (name == searchToolName) return searchToolDefinition;
    if (name == callToolName) return callToolDefinition;
    return _byName[name]?.definition;
  }

  /// The agent loop's view of [resolveCall]: `call_tool` becomes its target
  /// (a refusal and a corrected name included), `tool_search` is judged as
  /// the built-in it is. Synchronous, so like [lookup] it only knows
  /// servers already listed.
  @override
  ResolvedToolCall? resolve(ToolCall call, {required String sessionId}) {
    final r = resolveCall(call, sessionId: sessionId);
    if (!r.known) return null;
    final definition = r.call.name == searchToolName && r.refusal == null ? _searchGateDefinition : r.definition;
    return ResolvedToolCall(call: r.call, tool: definition, refusal: r.refusal, correctedName: r.correctedName);
  }

  @override
  Future<ToolResult> execute(ToolCall call, ToolExecutionContext context) async {
    if (call.name == searchToolName) return _search(call.arguments, context);
    if (call.name == callToolName) {
      var r = resolveCall(call, sessionId: context.sessionId);
      if (r.refusal != null && r.definition == callToolDefinition && await _loadMissing()) {
        r = resolveCall(call, sessionId: context.sessionId); // the target's server had not been listed yet
      }
      if (r.refusal != null) return ToolResult.error(r.refusal!);
      if (r.call.name == searchToolName) return _search(r.call.arguments, context);
      return _run(_byName[r.call.name]!, r.call, context);
    }
    var e = _byName[call.name];
    if (e == null && await _loadMissing()) e = _byName[call.name];
    if (e == null) return ToolResult.error('Unknown tool "${call.name}". Use only the tools provided.');
    return _run(e, call, context);
  }

  /// Lists enabled servers that were never listed (a call can arrive before
  /// any [toolsForTurn], e.g. when a run resumes after process death).
  /// Returns whether anything was loaded.
  Future<bool> _loadMissing() async {
    final missing = [
      for (final c in manager.servers)
        if (c.enabled && !_snapshots.containsKey(c.id)) c.id,
    ];
    if (missing.isEmpty) return false;
    await _ensureFresh();
    return missing.any(_snapshots.containsKey);
  }

  /// Runs a call to one of a server's tools on behalf of that server's MCP
  /// App view (R03 §3): only tools of the SAME server whose visibility
  /// includes `app`. The app must apply its approval policy first (an app
  /// can trigger destructive tools without the model).
  Future<ToolResult> executeForApp({
    required String serverId,
    required String toolName,
    required ToolExecutionContext context,
    JsonMap arguments = const {},
    String? callId,
  }) async {
    final e = _byKey[McpToolKey(serverId, toolName)];
    if (e == null) return ToolResult.error('Unknown tool "$toolName" on this server.');
    if (!e.tool.appCallable) return ToolResult.error('"$toolName" cannot be called from the app.');
    return _run(e, ToolCall(id: callId ?? 'app-${_clock.now().microsecondsSinceEpoch}', name: e.modelName, arguments: arguments),
        context,
        forModel: false);
  }

  /// The definition of a tool an app view may call (for its approval sheet).
  ToolDefinition? appToolDefinition(String serverId, String toolName) {
    final e = _byKey[McpToolKey(serverId, toolName)];
    return e != null && e.tool.appCallable ? e.definition : null;
  }

  /// Unwraps `call_tool` to its target and reports whether the router will
  /// refuse the call — for the approval layer and the UI, which must show
  /// (and decide on) the real tool, never the proxy.
  McpResolvedCall resolveCall(ToolCall call, {String? sessionId}) {
    if (call.name != callToolName) {
      final e = _byName[call.name];
      if (call.name == searchToolName) return McpResolvedCall(call: call, known: true, definition: searchToolDefinition);
      if (e == null) return McpResolvedCall(call: call, known: false);
      return McpResolvedCall(
        call: call,
        known: true,
        definition: e.definition,
        refusal: _refusal(e, sessionId, forModel: true),
      );
    }
    McpResolvedCall refuse(String why) =>
        McpResolvedCall(call: call, known: true, definition: callToolDefinition, viaProxy: true, refusal: why);
    final rawName = call.arguments['name'];
    if (rawName is! String || rawName.trim().isEmpty) {
      return refuse('call_tool needs "name": the exact tool name from tool_search.');
    }
    var args = call.arguments['arguments'];
    if (args is String && args.trim().startsWith('{')) {
      try {
        args = deepCopyJson(jsonDecode(args));
      } on FormatException {
        // reported below
      }
    }
    args ??= const <String, Object?>{};
    if (args is! Map) return refuse('call_tool "arguments" must be an object with the tool\'s parameters.');
    final arguments = args.cast<String, Object?>();
    final (name, corrected) = _resolveName(rawName.trim(), sessionId);
    if (name == null) return refuse('There is no tool named "${_clip(rawName, 80)}". Use tool_search to find the exact name.');
    if (name == callToolName) return refuse('call_tool cannot call itself.');
    final inner = ToolCall(
      id: call.id,
      name: name,
      arguments: arguments,
      repaired: call.repaired || corrected,
      rawArguments: call.rawArguments,
    );
    if (name == searchToolName) {
      return McpResolvedCall(
          call: inner, known: true, definition: searchToolDefinition, viaProxy: true, correctedName: corrected);
    }
    final e = _byName[name]!;
    return McpResolvedCall(
      call: inner,
      known: true,
      definition: e.definition,
      viaProxy: true,
      correctedName: corrected,
      refusal: _refusal(e, sessionId, forModel: true),
    );
  }

  /// Exact name, then case / `-`↔`_` / `functions.` normalization, then a
  /// unique wire-name match (server prefix left out), then a unique match
  /// within edit distance 2 (R11 §9.6.6 step 4).
  (String?, bool) _resolveName(String raw, String? sessionId) {
    if (raw == searchToolName || raw == callToolName) return (raw, false);
    if (_byName.containsKey(raw)) return (raw, false);
    bool usable(McpCatalogEntry e) => sessionId == null ? !e.quarantined && e.tool.modelVisible : _eligible(e, sessionId);
    String norm(String s) => s.toLowerCase().replaceAll('-', '_');
    var n = raw.startsWith('functions.') ? raw.substring('functions.'.length) : raw;
    n = norm(n);
    if (n == searchToolName || n == callToolName) return (n, true);
    final candidates = _catalog.where(usable).toList();
    final byNorm = [for (final e in candidates) if (norm(e.modelName) == n) e.modelName];
    if (byNorm.length == 1) return (byNorm.single, true);
    final byWire = [for (final e in candidates) if (norm(e.tool.name) == n) e.modelName];
    if (byWire.length == 1) return (byWire.single, true);
    final near = [for (final e in candidates) if (_editDistanceAtMost(norm(e.modelName), n, 2)) e.modelName];
    if (near.length == 1) return (near.single, true);
    return (null, false);
  }

  static bool _editDistanceAtMost(String a, String b, int k) {
    if ((a.length - b.length).abs() > k) return false;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
        rowMin = math.min(rowMin, cur[j]);
      }
      if (rowMin > k) return false;
      prev = cur;
    }
    return prev[b.length] <= k;
  }

  /// Why a call to [e] must not run now (model-facing), or null.
  String? _refusal(McpCatalogEntry e, String? sessionId, {required bool forModel}) {
    final server = manager.config(e.server.id) ?? e.server;
    switch (e.review.status) {
      case ToolReviewStatus.quarantinedNew:
        return '"${e.modelName}" has not been approved by the user yet, so it cannot run. Tell the user it is '
            'waiting for review in the tool settings.';
      case ToolReviewStatus.quarantinedChanged:
        return '"${e.modelName}" changed since the user approved it and is blocked until they review the change. '
            'Do not retry it; tell the user.';
      case ToolReviewStatus.approved:
        break;
    }
    if (forModel && !e.tool.modelVisible) return '"${e.modelName}" can only be used from its app view.';
    if (!server.enabled || (sessionId != null && !enablement.isServerEnabled(sessionId, server.id))) {
      return 'The "${server.name}" tools are turned off for this conversation.';
    }
    if (sessionId != null && forModel && !enablement.isToolEnabled(sessionId, e.modelName)) {
      return '"${e.modelName}" is turned off for this conversation.';
    }
    return null;
  }

  Future<ToolResult> _run(McpCatalogEntry e, ToolCall call, ToolExecutionContext ctx, {bool forModel = true}) async {
    final refusal = _refusal(e, ctx.sessionId, forModel: forModel);
    if (refusal != null) return ToolResult.error(refusal);
    var arguments = call.arguments;
    if (validateArgs) {
      final v = validateArguments(e.tool.inputSchema, arguments);
      if (!v.isValid) {
        return ToolResult.error('Invalid arguments for "${e.modelName}":\n${v.errors.take(3).join('\n')}\n'
            'Fix the arguments and call it again.');
      }
      arguments = v.value;
    }
    if (forModel) _touch(ctx.sessionId, e.modelName);
    // Diff on every list, also mid-segment: a server can change a tool
    // without `list_changed`. Non-blocking; this call uses the reviewed state.
    final snap = _snapshots[e.server.id];
    if (snap != null && _clock.now().difference(snap.fetchedAt) > maxCatalogAge) {
      unawaited(_refreshServer(e.server.id));
    }
    final budget = budgetFor(ctx.sessionId);
    try {
      final r = await manager.callTool(
        e.server.id,
        e.tool.name,
        arguments: arguments,
        cancel: ctx.cancel,
        timeout: ctx.timeout,
        maxTimeout: ctx.timeout,
        onProgress: ctx.onProgress,
        // Call ids repeat across turns (`call_0`); the loop's key is unique.
        idempotencyKey: ctx.idempotencyKey ?? '${ctx.sessionId}:${call.id}',
        // Only TRUSTED hints count (the effective annotations).
        retryOnReconnect: e.definition.annotations.isIdempotent,
      );
      final result = r.toToolResult(toolUiResourceUri: e.tool.uiResourceUri);
      final tagged = ToolResult(
        content: result.content,
        structured: result.structured,
        isError: result.isError,
        uiResourceUri: result.uiResourceUri,
        meta: {...result.meta, 'ai.sherpa/tool': e.modelName, 'ai.sherpa/serverId': e.server.id},
      );
      return limitToolResult(tagged, budget.resultLimits);
    } on CancelledException {
      rethrow;
    } on Object catch (err) {
      return ToolResult.error(_modelError(e, err, ctx));
    }
  }

  static String _clip(String s, [int max = 300]) {
    final r = Redactor.text(s.replaceAll(RegExp(r'\s+'), ' ').trim());
    return r.length > max ? '${r.substring(0, max - 1)}…' : r;
  }

  /// Model-friendly, redacted failure text. Server-supplied messages are
  /// quoted (they are tool output, i.e. untrusted data) and clipped.
  static String _modelError(McpCatalogEntry e, Object err, ToolExecutionContext ctx) {
    final name = e.modelName;
    final server = e.server.name;
    return switch (err) {
      McpServerUnavailableException() => err.modelMessage,
      McpCallInterruptedException() => err.modelMessage,
      McpTimeoutException() => '"$name" timed out after ${ctx.timeout.inSeconds} s. Try a smaller request or later.',
      McpAuthRequiredException() =>
        'The "$server" tool server needs the user to sign in again. Ask the user to reconnect it in the tool settings.',
      McpRpcException(:final error) when err.isInvalidParams =>
        '"$name" rejected the request: ${_clip(error.message)}. Fix the arguments and call it again.',
      McpRpcException(:final error) => '"$server" returned an error for "$name": ${_clip(error.message)}',
      McpInputDeclinedException() => '"$name" asked for input that was not given (the user declined, or Sherpa cannot '
          'provide that kind of input yet), so it could not finish. Do not retry it; tell the user if it matters.',
      McpTaskFailedException(:final error) => '"$name" failed: ${_clip(error?.message ?? 'no details given')}',
      McpLimitExceededException() => '"$name" returned more data than Sherpa accepts. Ask for less.',
      McpProtocolException() => '"$server" sent an invalid response for "$name".',
      McpConnectionClosedException() => 'The connection to "$server" closed. Try again later.',
      McpTransportException() => '"$server" could not be reached. Try again later or continue without it.',
      _ => '"$name" failed unexpectedly (${err.runtimeType}).',
    };
  }

  // ---------------------------------------------------------------- tool_search

  Bm25Index _ensureIndex() => _index ??= Bm25Index([
        for (final e in _catalog)
          if (!e.quarantined && e.tool.modelVisible)
            Bm25Document(id: e.modelName, fields: {
              'name': '${e.modelName} ${e.tool.name} ${e.tool.title ?? e.tool.annotations.title ?? ''}',
              'params': _paramNames(e.tool.inputSchema).join(' '),
              'description': '${e.tool.description ?? ''} ${e.server.name}',
            }),
      ]);

  static List<String> _paramNames(JsonMap schema) {
    final p = schema['properties'];
    return p is Map ? [for (final k in p.keys) '$k'] : const [];
  }

  /// Names ranked for [query] among [allowed]: BM25, fused with embedding
  /// similarity when an [embedder] is set.
  Future<List<String>> _rank(String query, Set<String> allowed, int limit) async {
    final index = _ensureIndex();
    final lexical = [for (final h in index.search(query, limit: limit * 3, filter: allowed.contains)) h.id];
    final emb = embedder;
    if (emb == null || allowed.isEmpty) return lexical.take(limit).toList();
    try {
      final names = allowed.toList()..sort();
      final missing = [for (final n in names) if (!_embeddings.containsKey(_embeddingKey(n))) n];
      if (missing.isNotEmpty) {
        final vectors = await emb.embed([for (final n in missing) _cardText(_byName[n]!)]);
        for (final (i, n) in missing.indexed) {
          if (i < vectors.length) _embeddings[_embeddingKey(n)] = vectors[i];
        }
      }
      final q = (await emb.embed([query])).first;
      final semantic = [
        for (final n in names)
          if (_embeddings[_embeddingKey(n)] case final v?) (n, cosineSimilarity(q, v)),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return reciprocalRankFusion([
        lexical,
        [for (final s in semantic.take(limit * 3)) s.$1],
      ]).take(limit).toList();
    } on Object {
      return lexical.take(limit).toList(); // the embedder is an optional layer
    }
  }

  String _embeddingKey(String name) => '$name:${_byName[name]?.review.currentHash}';

  static String _cardText(McpCatalogEntry e) =>
      '${e.modelName}: ${e.tool.description ?? ''} (${_paramNames(e.tool.inputSchema).join(', ')})';

  Future<ToolResult> _search(JsonMap args, ToolExecutionContext ctx) async {
    final budget = budgetFor(ctx.sessionId);
    final rawQuery = args['query'];
    final query = (rawQuery is String ? rawQuery : (rawQuery == null ? '' : '$rawQuery')).trim();
    final rawLimit = args['limit'];
    final limit = (rawLimit is num ? rawLimit.toInt() : int.tryParse('$rawLimit') ?? budget.searchLimit).clamp(1, 10);
    await _ensureFresh();
    final eligible = [for (final e in _catalog) if (_eligible(e, ctx.sessionId)) e];
    if (eligible.isEmpty) return ToolResult.text('No additional tools are available in this conversation.');
    final allowed = {for (final e in eligible) e.modelName};

    final exact = query.isEmpty ? null : _resolveName(query, ctx.sessionId).$1;
    final List<McpCatalogEntry> hits;
    if (exact != null && allowed.contains(exact)) {
      hits = [_byName[exact]!];
    } else if (query.isEmpty) {
      hits = eligible.take(limit).toList();
    } else {
      hits = [for (final n in await _rank(query, allowed, limit)) _byName[n]!];
    }
    if (hits.isEmpty) {
      final groups = <String, int>{};
      for (final e in eligible) {
        groups[e.server.name] = (groups[e.server.name] ?? 0) + 1;
      }
      return ToolResult.text('No tools match "${_clip(query, 80)}". Try other words, such as the action or the '
          'service. Tool groups available: ${groups.entries.map((g) => '${g.key} (${g.value})').join(', ')}.');
    }
    final full = hits.length == 1 && exact != null;
    final cards = [for (final e in hits) _card(e, budget, full: full)];
    final text = StringBuffer(full
        ? 'Tool details. Run it with call_tool(name, arguments):\n'
        : '${hits.length} matching tool${hits.length == 1 ? '' : 's'}. Run one with call_tool(name, arguments):\n');
    for (final c in cards) {
      final params = (c['parameters']! as List).cast<JsonMap>();
      text.write('- ${c['name']}: ${c['description']}');
      String arg(JsonMap p) => '${p['name']} (${p['type']}${p['required'] == true ? ', required' : ''})';
      text.write(params.isEmpty ? ' Arguments: none.' : ' Arguments: ${params.map(arg).join(', ')}.');
      if (c['schema'] != null) text.write('\n  Schema: ${jsonEncode(c['schema'])}');
      text.writeln();
    }
    return ToolResult(
      content: [TextPart(text.toString().trimRight())],
      structured: {'tools': cards},
      meta: const {'ai.sherpa/toolSearch': true},
    );
  }

  /// A compact tool card: name, one-line description, parameter names and
  /// types; with [full], the (rendered) input schema too.
  JsonMap _card(McpCatalogEntry e, ToolBudget budget, {required bool full}) {
    final schema = e.tool.inputSchema;
    final props = schema['properties'];
    final req = schema['required'] is List ? {...(schema['required']! as List).whereType<String>()} : <String>{};
    final params = <JsonMap>[
      if (props is Map)
        for (final p in props.entries.take(12))
          {'name': '${p.key}', 'type': _typeLabel(p.value), if (req.contains(p.key)) 'required': true},
    ];
    return {
      'name': e.modelName,
      'description': _oneLine(e.tool.description ?? e.tool.title ?? ''),
      'parameters': params,
      if (full) 'schema': _render(e, budget).inputSchema,
    };
  }

  static String _typeLabel(Object? s) {
    if (s is! Map) return 'any';
    final en = s['enum'];
    if (en is List && en.isNotEmpty && en.length <= 5) {
      return 'one of ${en.map((v) => v is String ? v : jsonEncode(v)).join('|')}';
    }
    final t = s['type'];
    final items = s['items'];
    if (t == 'array' && items is Map && items['type'] is String) return '${items['type']}[]';
    if (t is String) return t;
    if (t is List) return t.whereType<String>().where((x) => x != 'null').join('|');
    if (s['anyOf'] is List || s['oneOf'] is List) return 'varies';
    if (s['properties'] is Map) return 'object';
    return 'any';
  }

  static String _oneLine(String text) {
    final t = text.replaceAll(RegExp(r'[\u0000-\u001F\u007F]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final first = RegExp(r'^.*?[.!?](?=\s|$)').firstMatch(t)?.group(0) ?? t;
    return first.length > 140 ? '${first.substring(0, 139)}…' : first;
  }

  /// Stops listening to the manager and hygiene (does not dispose them).
  Future<void> dispose() async {
    _disposed = true;
    await _managerSub.cancel();
    await _hygieneSub.cancel();
  }
}

/// The live MCP App views of the app and their controllers.
///
/// Each view (one tool call's `ui://` resource in one chat) gets an entry
/// that outlives its widget: the resource, the [McpAppController] with its
/// buffered tool data, and the callbacks wired to the app's real services.
/// At most [McpAppViewPool.maxLive] WebViews run at once: a view that
/// scrolls out of sight (or whose page is covered) is suspended after
/// [McpAppViewPool.hiddenGrace] — `ui/resource-teardown` is delivered while
/// its widget is still mounted — and the least recently seen hidden views
/// are suspended as soon as the pool is over budget. A suspended view
/// re-renders from its stored tool input and result when it is shown again.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

import '../../app_info.dart';
import '../../services/mcp/mcp_runtime.dart';
import '../mcp/state/input_providers.dart';
import '../mcp/state/mcp_providers.dart';
import 'state/apps_providers.dart';

/// Where a view's resource is.
enum McpAppEntryStatus { loading, ready, unavailable }

/// What an entry needs from the widget showing it: sheets, in that
/// widget's context.
abstract interface class McpAppPrompter {
  Future<ApprovalResponse?> confirmToolCall(McpAppToolCallRequest request, ToolDefinition tool, NeedsConfirmation requirement);

  Future<bool> confirmMessage(McpAppMessageRequest request);

  Future<bool> confirmOpenLink(McpAppLinkRequest request);

  /// Granted origins, `{}` to keep offline, null for "not now".
  Future<Set<String>?> requestNetwork(McpAppNetworkRequest request);
}

/// What a view shows: a tool call's (or a stored part's) UI resource.
final class McpAppViewSpec {
  const McpAppViewSpec({
    required this.sessionId,
    required this.serverId,
    required this.resourceUri,
    this.callId,
    this.toolModelName,
    this.result,
    this.toolArguments,
  });

  final String sessionId;
  final String serverId;
  final String resourceUri;
  final String? callId;

  /// The model-facing tool name (`ai.sherpa/tool`, else the part's name).
  final String? toolModelName;
  final ToolResultPart? result;
  final JsonMap? toolArguments;

  String get key => '$sessionId|$serverId|$resourceUri|${callId ?? ''}';
}

/// One view's state, kept across scrolling and rebuilds.
final class McpAppViewEntry extends ChangeNotifier {
  McpAppViewEntry._(this.spec, this.serverName);

  final McpAppViewSpec spec;
  final String serverName;
  McpAppEntryStatus _status = McpAppEntryStatus.loading;
  String? _unavailable;
  McpAppController? _controller;
  McpAppResource? _resource;
  final List<McpAppPrompter> _prompters = [];
  bool _visible = false;

  /// The widget reported at least once (until then the view counts as
  /// on screen: it was just built).
  bool _visibilityKnown = false;
  int _lastSeen = 0;
  Timer? _hideTimer;
  int _approvals = 0;
  final CancellationToken _cancel = CancellationToken();
  bool _closed = false;

  McpAppEntryStatus get status => _status;

  /// Why the view can't be shown (the text fallback is shown instead).
  String? get unavailableReason => _unavailable;
  McpAppController? get controller => _controller;
  McpAppResource? get resource => _resource;
  bool get visible => _visible;
  String get serverId => spec.serverId;

  /// Dropped by the pool (apps turned off, consent revoked, chat closed):
  /// the widget asks the pool for a fresh entry.
  bool get isClosed => _closed;

  McpAppPrompter? get _prompter => _prompters.isEmpty ? null : _prompters.last;

  bool get _live {
    final c = _controller;
    if (c == null) return false;
    return switch (c.status) {
      McpAppViewStatus.consent || McpAppViewStatus.starting || McpAppViewStatus.loading || McpAppViewStatus.ready => true,
      _ => false,
    };
  }

  bool get _fullscreen => _controller?.displayMode == McpAppDisplayMode.fullscreen;

  void _set(McpAppEntryStatus s, [String? why]) {
    if (_closed) return;
    _status = s;
    _unavailable = why;
    notifyListeners();
  }

  /// Tears the view down (teardown request while it is still mounted). The
  /// notifier itself stays usable: a widget may still be listening and
  /// moves to a fresh entry on the notification.
  void _close() {
    if (_closed) return;
    _closed = true;
    _hideTimer?.cancel();
    _cancel.cancel('view closed');
    final c = _controller;
    if (c != null) unawaited(c.close().catchError((Object _) {}));
    notifyListeners();
  }
}

final class McpAppViewPool {
  McpAppViewPool(this._ref, {this.maxLive = 3, this.hiddenGrace = const Duration(seconds: 5), this.maxEntries = 24});

  final Ref _ref;

  /// Live WebViews at once (2–3 per R03 §11.8).
  final int maxLive;

  /// How long a hidden view stays live before it is suspended.
  final Duration hiddenGrace;

  /// Entries (controllers with tool data) kept for re-rendering.
  final int maxEntries;

  final Map<String, McpAppViewEntry> _entries = {};
  StreamSubscription<String>? _settingsSub;
  int _seen = 0;
  bool _disposed = false;

  McpRuntime get _rt => _ref.read(mcpRuntimeProvider);

  /// Live views now (for tests and diagnostics).
  int get liveCount => _entries.values.where((e) => e._live).length;

  Iterable<McpAppViewEntry> get entries => _entries.values;

  void _watchSettings() {
    _settingsSub ??= _rt.hostSettings.changes.listen(_onSettings);
  }

  /// Apps turned off, or a network consent revoked: the server's views
  /// are closed (they show text, or ask again when shown).
  void _onSettings(String serverId) {
    final s = _rt.hostSettingsOf(serverId);
    for (final e in [..._entries.values]) {
      if (e.serverId != serverId) continue;
      if (!s.appsEnabled) {
        _drop(e);
        continue;
      }
      final r = e._resource;
      final c = e._controller;
      if (r == null || c == null) continue;
      final now = _rt.hostSettings.grantedOrigins(serverId, r.sha256);
      final had = c.grantedOrigins;
      if (had != null && !r.declared.isEmpty && !_sameSet(now, had)) _drop(e);
    }
  }

  static bool _sameSet(Set<String>? a, Set<String>? b) =>
      a == null || b == null ? a == b : a.length == b.length && a.containsAll(b);

  void _drop(McpAppViewEntry e) {
    _entries.remove(e.spec.key);
    e._close();
  }

  /// The entry for [spec], created (and its resource loading) on first use.
  McpAppViewEntry entryFor(McpAppViewSpec spec) {
    _watchSettings();
    final existing = _entries[spec.key];
    if (existing != null && !existing._closed) return existing;
    final e = McpAppViewEntry._(spec, _rt.server(spec.serverId)?.name ?? spec.serverId);
    _entries[spec.key] = e;
    _trim();
    unawaited(_load(e));
    return e;
  }

  Future<void> _load(McpAppViewEntry e) async {
    final rt = _rt;
    final spec = e.spec;
    if (!rt.hostSettingsOf(spec.serverId).appsEnabled) {
      e._set(McpAppEntryStatus.unavailable, 'Interactive content is turned off for this server.');
      return;
    }
    if (rt.server(spec.serverId) == null) {
      e._set(McpAppEntryStatus.unavailable, 'The server was removed.');
      return;
    }
    try {
      final resource = await loadMcpAppResource(rt.manager, serverId: spec.serverId, uri: spec.resourceUri);
      if (e._closed) return;
      final wire = spec.toolModelName == null ? null : rt.router.entryFor(spec.toolModelName!)?.tool.name;
      Map<String, Object?>? tool;
      if (wire != null) {
        try {
          tool = await mcpToolJson(rt.manager, spec.serverId, wire, router: rt.router);
        } on Object {
          tool = null;
        }
      }
      if (e._closed) return;
      e._resource = resource;
      final c = McpAppController(
        session: McpAppSession(
          serverId: spec.serverId,
          serverName: e.serverName,
          resource: resource,
          tool: tool,
          callId: spec.callId,
        ),
        callbacks: _callbacks(e),
        platform: _ref.read(mcpAppPlatformProvider),
        hostContext: McpAppHostContext(
          userAgent: 'Sherpa/${AppInfo.version} (mobile)',
          timeZone: _ref.read(mcpAppTimeZoneProvider),
        ),
        grantedOrigins: rt.hostSettings.grantedOrigins(spec.serverId, resource.sha256),
        hostInfo: const {'name': 'sherpa', 'title': 'Sherpa', 'version': AppInfo.version},
      );
      final args = spec.toolArguments;
      final result = spec.result;
      if (args != null || result != null) c.setToolInput(args ?? const {});
      if (result != null) c.setToolResultPart(result);
      e._controller = c;
      c.addListener(() => _onControllerChanged(e));
      e._set(McpAppEntryStatus.ready);
    } on McpAppResourceException catch (err) {
      e._set(McpAppEntryStatus.unavailable, "The server's interactive view is not valid (${err.message}).");
    } on Object catch (err) {
      e._set(McpAppEntryStatus.unavailable, 'The interactive view could not be loaded (${err.runtimeType}).');
    }
  }

  void _onControllerChanged(McpAppViewEntry e) {
    if (e._live) _enforce();
  }

  McpAppHostCallbacks _callbacks(McpAppViewEntry e) {
    final rt = _rt;
    final spec = e.spec;
    final sink = _ref.read(mcpAppMessageSinkProvider);
    return mcpRouterAppCallbacks(
      router: rt.router,
      manager: rt.manager,
      serverId: spec.serverId,
      sessionId: spec.sessionId,
      approveToolCall: (req) => _approve(e, req),
      confirmMessage: sink == null ? null : (req) async => await e._prompter?.confirmMessage(req) ?? false,
      insertMessage: sink == null
          ? null
          : (req) => sink(McpAppInsertedMessage(sessionId: spec.sessionId, text: req.text, identity: req.identity, callId: spec.callId)),
      confirmOpenLink: (req) async => await e._prompter?.confirmOpenLink(req) ?? false,
      launchLink: (uri) => _ref.read(mcpUrlOpenerProvider).open(uri),
      updateModelContext: (ctx) => _ref.read(mcpAppModelContextsProvider).set(spec.sessionId, spec.key, ctx),
      requestNetworkAccess: (req) async {
        final granted = await e._prompter?.requestNetwork(req);
        if (granted == null) return const {};
        await rt.hostSettings.setGrantedOrigins(req.serverId, req.resourceSha256, granted, resourceUri: req.resourceUri);
        return granted;
      },
    );
  }

  /// App-initiated calls: the same policy as the model's, evaluated as
  /// TAINTED (an untrusted view drives them), then the chat's approval UI
  /// if it provided one, else the apps approval sheet. A remembered grant
  /// is recorded through the policy.
  Future<bool> _approve(McpAppViewEntry e, McpAppToolCallRequest req) async {
    final rt = _rt;
    final spec = e.spec;
    final def = req.tool.definition ?? rt.router.appToolDefinition(spec.serverId, req.tool.name);
    if (def == null) return false;
    final policy = rt.policy;
    final requirement = policy.evaluate(def, spec.sessionId, tainted: true);
    switch (requirement) {
      case AutoApprove():
        return true;
      case Denied():
        return false;
      case final NeedsConfirmation n:
        ApprovalResponse? response;
        final handler = _ref.read(mcpAppApprovalHandlerProvider)(spec.sessionId);
        if (handler != null) {
          response = await handler.requestApproval(
            sessionId: spec.sessionId,
            call: ToolCall(id: 'app-${spec.callId ?? 'view'}-${++e._approvals}', name: def.name, arguments: req.arguments),
            tool: def,
            requirement: n,
            cancel: e._cancel,
          );
        } else {
          response = await e._prompter?.confirmToolCall(req, def, n);
        }
        if (response == null || response.decision != UserDecision.approve) return false;
        // The policy never stores "always" for a destructive (or untrusted) tool.
        policy.recordFor(def, spec.sessionId, response, requirement: n);
        return true;
    }
  }

  // ------------------------------------------------------------- widgets

  void attach(McpAppViewEntry e, McpAppPrompter p) {
    if (!e._prompters.contains(p)) e._prompters.add(p);
  }

  void detach(McpAppViewEntry e, McpAppPrompter p) {
    e._prompters.remove(p);
    if (e._prompters.isEmpty) setVisible(e, false);
  }

  /// The widget reports whether its view is on screen.
  void setVisible(McpAppViewEntry e, bool visible) {
    if (e._closed || (e._visibilityKnown && e._visible == visible)) return;
    e._visibilityKnown = true;
    e._visible = visible;
    e._hideTimer?.cancel();
    e._hideTimer = null;
    if (visible) {
      e._lastSeen = ++_seen;
      final c = e._controller;
      if (c != null && e._prompters.isNotEmpty && (c.status == McpAppViewStatus.suspended || c.status == McpAppViewStatus.idle)) {
        unawaited(c.start());
      }
      _enforce();
    } else {
      e._hideTimer = Timer(hiddenGrace, () {
        e._hideTimer = null;
        if (!e._visible && !e._fullscreen) unawaited(_suspend(e));
      });
      _enforce();
    }
  }

  Future<void> _suspend(McpAppViewEntry e) async {
    final c = e._controller;
    if (c == null || !e._live || e._fullscreen) return;
    await c.suspend();
  }

  bool _enforceScheduled = false;

  /// Over budget: suspend the least recently seen hidden views (visible,
  /// fullscreen and not yet measured ones are kept). Deferred to a
  /// microtask (and coalesced): it can be triggered while widgets are
  /// being unmounted, when nothing may rebuild.
  void _enforce() {
    if (_enforceScheduled || _disposed) return;
    _enforceScheduled = true;
    scheduleMicrotask(() {
      _enforceScheduled = false;
      if (!_disposed) _enforceNow();
    });
  }

  void _enforceNow() {
    final live = [for (final e in _entries.values) if (e._live) e]..sort((a, b) => a._lastSeen.compareTo(b._lastSeen));
    var over = live.length - maxLive;
    for (final e in live) {
      if (over <= 0) break;
      if (!e._visibilityKnown || e._visible || e._fullscreen) continue;
      unawaited(_suspend(e));
      over--;
    }
  }

  /// Too many entries: close the least recently seen detached ones.
  void _trim() {
    if (_entries.length <= maxEntries) return;
    final idle = [for (final e in _entries.values) if (e._prompters.isEmpty && !e._visible) e]
      ..sort((a, b) => a._lastSeen.compareTo(b._lastSeen));
    for (final e in idle.take(_entries.length - maxEntries)) {
      _entries.remove(e.spec.key);
      e._close();
    }
  }

  /// Closes every view of [sessionId] (the chat was closed or deleted).
  void closeSession(String sessionId) {
    for (final e in [..._entries.values]) {
      if (e.spec.sessionId == sessionId) {
        _entries.remove(e.spec.key);
        e._close();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_settingsSub?.cancel());
    for (final e in _entries.values) {
      e._close();
    }
    _entries.clear();
  }
}

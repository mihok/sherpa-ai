/// Input requests from MCP servers waiting for the user: elicitation forms,
/// URL consent and sampling approval, in arrival order.
///
/// The [InteractiveInputHandler] enqueues; the UI (the in-app banner and
/// sheets, a chat's inline cards) answers. Requests can arrive while the app
/// is in the background or the chat is not on screen, so nothing here needs
/// a widget: an unanswered request times out with a polite decline, and one
/// whose originating call was cancelled closes on its own.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, protected;
import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, Clock, SystemClock;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'elicitation_form.dart';

/// How a request ended, for the history and the server's console.
enum McpInputOutcome { accepted, declined, cancelled, timedOut, refused, failed }

/// Where a URL elicitation is.
enum UrlElicitationStage {
  /// The consent sheet: full URL, domain, the server's reason.
  consent,

  /// Opened in the browser; waiting for the user to finish there.
  opened,

  /// Opening failed (no browser, refused by the OS).
  failed,
}

/// Where a sampling request is.
enum SamplingStage {
  /// The approval sheet (skipped when the server is allowed for the chat).
  approval,

  /// The model is writing.
  running,

  /// The answer is shown for review before it goes back to the server.
  review,

  /// The model failed; [PendingSampling.error] says why.
  failed,
}

/// One request waiting for the user. Listenable: the sheet showing it
/// rebuilds on [notifyListeners] (stage changes, completion).
sealed class McpPendingInput {
  McpPendingInput._({
    required this.id,
    required this.context,
    required this.receivedAt,
    required this.deadline,
    required this.serverTrusted,
  });

  final String id;
  final McpInputContext context;
  final DateTime receivedAt;

  /// When it is declined for lack of an answer.
  final DateTime deadline;

  /// The user trusts this server (the UI still frames its text as content).
  final bool serverTrusted;

  final List<void Function()> _listeners = [];
  bool _done = false;
  McpInputOutcome? _outcome;
  McpInputQueue? _queue;

  String get serverId => context.serverId;
  String get serverName => context.serverName;

  /// The chat the request belongs to, when known.
  String? get sessionId => context.origin?.sessionId;

  /// The tool whose call asked (model-facing name), when known.
  String? get toolName => context.origin?.toolName ?? context.originName;

  bool get isDone => _done;
  McpInputOutcome? get outcome => _outcome;

  /// Short line for banners and inline cards ("asks you to fill in a form").
  String get summary;

  void addListener(void Function() l) => _listeners.add(l);

  void removeListener(void Function() l) => _listeners.remove(l);

  @protected
  void notifyListeners() {
    for (final l in List.of(_listeners)) {
      l();
    }
    _queue?._changed();
  }

  /// Ends the request with what a timeout means for its kind.
  @protected
  void timeOut();

  /// Ends the request because its call was cancelled.
  @protected
  void abandon();

  @protected
  bool finish(McpInputOutcome outcome) {
    if (_done) return false;
    _done = true;
    _outcome = outcome;
    notifyListeners();
    _queue?._remove(this);
    return true;
  }
}

/// A form-mode elicitation.
final class PendingFormElicitation extends McpPendingInput {
  PendingFormElicitation._({
    required super.id,
    required super.context,
    required super.receivedAt,
    required super.deadline,
    required super.serverTrusted,
    required this.request,
    required this.form,
  }) : super._();

  final McpElicitRequest request;
  final ElicitationForm form;
  final Completer<McpElicitResult> _result = Completer();

  Future<McpElicitResult> get result => _result.future;

  @override
  String get summary => 'asks you to fill in a form';

  /// Sends the reviewed answers. Returns false when [content] does not
  /// validate (nothing is sent) or the request already ended.
  bool accept(Map<String, Object?> values) {
    if (isDone || !form.canAccept || form.validate(values).isNotEmpty) return false;
    final content = form.content(values);
    if (!finish(McpInputOutcome.accepted)) return false;
    _result.complete(McpElicitResult.accept(content));
    return true;
  }

  void decline() {
    if (finish(McpInputOutcome.declined)) _result.complete(const McpElicitResult.decline());
  }

  void cancel() {
    if (finish(McpInputOutcome.cancelled)) _result.complete(const McpElicitResult.cancel());
  }

  @override
  void timeOut() {
    if (finish(McpInputOutcome.timedOut)) _result.complete(const McpElicitResult.decline());
  }

  @override
  void abandon() {
    if (finish(McpInputOutcome.cancelled)) _result.complete(const McpElicitResult.cancel());
  }
}

/// A URL-mode elicitation: consent, then the page opens outside the app.
final class PendingUrlElicitation extends McpPendingInput {
  PendingUrlElicitation._({
    required super.id,
    required super.context,
    required super.receivedAt,
    required super.deadline,
    required super.serverTrusted,
    required this.request,
  }) : super._();

  final McpElicitRequest request;
  final Completer<McpElicitResult> _result = Completer();
  UrlElicitationStage _stage = UrlElicitationStage.consent;
  String? _error;

  Future<McpElicitResult> get result => _result.future;

  Uri get url => request.url!;

  UrlElicitationStage get stage => _stage;

  String? get error => _error;

  @override
  String get summary => 'asks you to open a web page';

  /// The user consented and the page was opened.
  void markOpened() {
    if (isDone) return;
    _stage = UrlElicitationStage.opened;
    _error = null;
    notifyListeners();
  }

  /// Opening failed; the sheet offers a retry.
  void markFailed(String why) {
    if (isDone) return;
    _stage = UrlElicitationStage.failed;
    _error = why;
    notifyListeners();
  }

  /// The user is back (or the server said it is done): the request is
  /// answered `accept` ("the user consented to open the URL") and the
  /// server checks the outcome when the call is retried.
  void complete() {
    if (_stage != UrlElicitationStage.opened) return;
    if (finish(McpInputOutcome.accepted)) _result.complete(const McpElicitResult.accept());
  }

  void decline() {
    if (finish(McpInputOutcome.declined)) _result.complete(const McpElicitResult.decline());
  }

  void cancel() {
    if (finish(McpInputOutcome.cancelled)) _result.complete(const McpElicitResult.cancel());
  }

  @override
  void timeOut() {
    if (_stage == UrlElicitationStage.opened) {
      // The page was opened: let the server look at the outcome.
      if (finish(McpInputOutcome.accepted)) _result.complete(const McpElicitResult.accept());
      return;
    }
    if (finish(McpInputOutcome.timedOut)) _result.complete(const McpElicitResult.decline());
  }

  @override
  void abandon() {
    if (finish(McpInputOutcome.cancelled)) _result.complete(const McpElicitResult.cancel());
  }
}

/// Limits applied to one sampling request (from the server's settings).
@immutable
final class SamplingLimits {
  const SamplingLimits({required this.maxTokens, required this.requestedMaxTokens, this.requestedContext});

  /// What the model may write: the request's `maxTokens`, capped by the
  /// server's setting.
  final int maxTokens;

  /// What the server asked for.
  final int requestedMaxTokens;

  /// `includeContext` the server asked for (`thisServer` / `allServers`,
  /// both deprecated). Sherpa shares no conversation context with servers,
  /// so this is shown and refused, never honoured.
  final String? requestedContext;

  bool get capped => maxTokens < requestedMaxTokens;

  bool get contextRefused => requestedContext != null && requestedContext != 'none';
}

/// The model's answer as the user reviews it.
@immutable
final class SamplingDraft {
  const SamplingDraft({required this.text, required this.model, required this.modelLabel, this.stopReason, this.outputTokens});

  final String text;

  /// The model id reported to the server.
  final String model;

  /// What the review sheet calls it.
  final String modelLabel;
  final String? stopReason;
  final int? outputTokens;
}

/// A `sampling/createMessage` request.
final class PendingSampling extends McpPendingInput {
  PendingSampling._({
    required super.id,
    required super.context,
    required super.receivedAt,
    required super.deadline,
    required super.serverTrusted,
    required this.request,
    required this.limits,
    required this.preApproved,
  })  : _stage = preApproved ? SamplingStage.running : SamplingStage.approval,
        super._();

  final McpSamplingRequest request;
  final SamplingLimits limits;

  /// Allowed for this chat (or for every chat in the server's settings):
  /// the approval sheet is skipped, the answer is still reviewed.
  final bool preApproved;
  final Completer<McpSamplingResult> _result = Completer();
  final CancellationToken runCancel = CancellationToken();
  SamplingStage _stage;
  SamplingDraft? _draft;
  String? _error;

  /// What the user approved: the (possibly edited) prompt.
  String? approvedPrompt;

  /// The user chose "Allow for this chat".
  bool allowedForChat = false;

  Future<McpSamplingResult> get result => _result.future;

  SamplingStage get stage => _stage;

  SamplingDraft? get draft => _draft;

  String? get error => _error;

  @override
  String get summary => 'asks to use your model';

  /// The user allowed it ([prompt] is the edited last user message, if
  /// they changed it). The UI then runs the model and calls [setDraft].
  void approve({String? prompt, bool forChat = false}) {
    if (isDone || _stage != SamplingStage.approval) return;
    approvedPrompt = prompt;
    allowedForChat = forChat;
    _stage = SamplingStage.running;
    notifyListeners();
  }

  void setDraft(SamplingDraft draft) {
    if (isDone) return;
    _draft = draft;
    _stage = SamplingStage.review;
    notifyListeners();
  }

  void setFailed(String why) {
    if (isDone) return;
    _error = why;
    _stage = SamplingStage.failed;
    notifyListeners();
  }

  /// Sends the reviewed answer ([text] if the user edited it).
  bool send({String? text}) {
    final d = _draft;
    if (isDone || _stage != SamplingStage.review || d == null) return false;
    final body = text ?? d.text;
    if (!finish(McpInputOutcome.accepted)) return false;
    _result.complete(McpSamplingResult(
      content: [McpTextContent(body)],
      model: d.model,
      stopReason: d.stopReason ?? 'endTurn',
    ));
    return true;
  }

  /// Deny (before running) or discard the answer (after).
  void deny([String reason = 'The user did not allow this request to use their model.']) {
    runCancel.cancel('denied');
    if (finish(McpInputOutcome.declined)) _result.completeError(InputRequestDeclined(reason));
  }

  @override
  void timeOut() {
    runCancel.cancel('timed out');
    if (finish(McpInputOutcome.timedOut)) {
      _result.completeError(const InputRequestDeclined('Nobody answered in time, so Sherpa declined this request.'));
    }
  }

  @override
  void abandon() {
    runCancel.cancel('cancelled');
    if (finish(McpInputOutcome.cancelled)) _result.completeError(const InputRequestDeclined('The request was cancelled.'));
  }
}

/// Something the user should hear about without having to answer it
/// (a refused form, a declined request).
@immutable
final class McpInputNotice {
  const McpInputNotice({required this.serverId, required this.serverName, required this.message});

  final String serverId;
  final String serverName;
  final String message;
}

/// The pending requests, oldest first.
final class McpInputQueue {
  McpInputQueue({Clock clock = const SystemClock(), this.timeout = const Duration(minutes: 5)}) : _clock = clock;

  final Clock _clock;

  /// How long a request waits for the user before it is declined.
  final Duration timeout;

  final List<McpPendingInput> _pending = [];
  final Map<String, Timer> _timers = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<McpInputNotice> _notices = StreamController<McpInputNotice>.broadcast();
  int _seq = 0;
  bool _disposed = false;

  List<McpPendingInput> get pending => List.unmodifiable(_pending);

  /// Every add, removal and stage change.
  Stream<void> get changes => _changes.stream;

  /// Things to tell the user (snackbars).
  Stream<McpInputNotice> get notices => _notices.stream;

  /// Pending requests of one chat.
  List<McpPendingInput> forSession(String sessionId) => [for (final p in _pending) if (p.sessionId == sessionId) p];

  McpPendingInput? byId(String id) => _pending.where((p) => p.id == id).firstOrNull;

  void notice(McpInputNotice n) {
    if (!_disposed) _notices.add(n);
  }

  PendingFormElicitation addForm(McpElicitRequest request, ElicitationForm form, McpInputContext context, {bool trusted = false}) =>
      _add(PendingFormElicitation._(
        id: _nextId(),
        context: context,
        receivedAt: _clock.now(),
        deadline: _clock.now().add(timeout),
        serverTrusted: trusted,
        request: request,
        form: form,
      ));

  PendingUrlElicitation addUrl(McpElicitRequest request, McpInputContext context, {bool trusted = false}) =>
      _add(PendingUrlElicitation._(
        id: _nextId(),
        context: context,
        receivedAt: _clock.now(),
        deadline: _clock.now().add(timeout),
        serverTrusted: trusted,
        request: request,
      ));

  PendingSampling addSampling(
    McpSamplingRequest request,
    SamplingLimits limits,
    McpInputContext context, {
    bool trusted = false,
    bool preApproved = false,
  }) =>
      _add(PendingSampling._(
        id: _nextId(),
        context: context,
        receivedAt: _clock.now(),
        deadline: _clock.now().add(timeout),
        serverTrusted: trusted,
        request: request,
        limits: limits,
        preApproved: preApproved,
      ));

  String _nextId() => 'input-${++_seq}';

  T _add<T extends McpPendingInput>(T p) {
    if (_disposed) {
      p.timeOut();
      return p;
    }
    p._queue = this;
    _pending.add(p);
    _timers[p.id] = Timer(timeout, p.timeOut);
    final cancel = p.context.cancel;
    if (cancel.isCancelled) {
      p.abandon();
      return p;
    }
    unawaited(cancel.whenCancelled.then((_) => p.abandon()));
    _changed();
    return p;
  }

  void _remove(McpPendingInput p) {
    _timers.remove(p.id)?.cancel();
    if (_pending.remove(p)) _changed();
  }

  void _changed() {
    if (!_disposed) _changes.add(null);
  }

  /// Declines everything [serverId] is waiting for (the server was removed).
  void dropServer(String serverId) {
    for (final p in List.of(_pending)) {
      if (p.serverId == serverId) p.timeOut();
    }
  }

  /// Declines everything still waiting.
  void dispose() {
    if (_disposed) return;
    for (final p in List.of(_pending)) {
      p.timeOut();
    }
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    unawaited(_changes.close());
    unawaited(_notices.close());
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../availability.dart';
import '../backend.dart';
import '../common/errors.dart';
import '../common/event_router.dart';
import '../common/history_planner.dart';
import '../common/serial_queue.dart';
import '../common/wire.dart';
import '../messages.pigeon.dart';
import 'fm_schema.dart';

/// Provider-wide policy for Apple Foundation Models (POLICY / UNVERIFIED).
@immutable
final class FmProviderConfig {
  const FmProviderConfig({
    this.maxTools = 5,
    this.toolSettle = const Duration(milliseconds: 150),
    this.toolResultTimeout = const Duration(minutes: 5),
    this.cancelGrace = const Duration(seconds: 2),
    this.statusTtl = const Duration(seconds: 30),
    this.continuePrompt = 'Continue.',
  });

  /// Apple: keep it to 3–5 tools per request; definitions eat the 4K context
  /// (R06 §3.3). Extra tools are dropped with a notice.
  final int maxTools;

  /// After a tool request, how long to wait for parallel ones before ending
  /// the Dart stream with `Finish(toolCalls)`.
  final Duration toolSettle;

  /// How long a native turn may stay suspended in `Tool.call` waiting for the
  /// agent loop's results before it is cancelled.
  final Duration toolResultTimeout;
  final Duration cancelGrace;

  /// How long a [AppleFoundationModelsProvider.status] verdict is reused by
  /// [AppleFoundationModelsProvider.stream].
  final Duration statusTtl;

  /// The prompt sent when a request ends with something Foundation Models
  /// cannot answer directly (tool results whose suspended turn is gone, or a
  /// paused reply): the history is rebuilt and this user turn is added.
  final String continuePrompt;
}

/// [ModelProvider] for Apple's on-device system model
/// (`SystemLanguageModel.default`, iOS 26+ with Apple Intelligence).
///
/// * One `LanguageModelSession` per Sherpa session, streamed; snapshots are
///   diffed natively into deltas. History policy: [HistoryPlanner] with
///   [AppendShape.singleUserPrompt] (one prompt per turn); a changed
///   instruction or tool set, a branch, an edit or compaction rebuilds the
///   session from a `Transcript` built from the request.
/// * Tools: Sherpa's JSON schemas become `DynamicGenerationSchema`s
///   ([FmSchemaConverter]). When the model calls a tool, the Swift
///   `Tool.call` SUSPENDS and the call is reported here; this stream ends
///   with `Finish(toolCalls)`; the agent loop runs the tool (approvals and
///   all); the next request, which ends with the tool results, resumes the
///   same native call and streams the rest of the reply. A request that does
///   not answer the suspended calls cancels that turn and rebuilds.
/// * Guided generation: `GenerationParams.jsonSchema` →
///   `streamResponse(to:schema:)`; the final JSON arrives as one delta.
/// * Context overflow (`GenerationError.exceededContextWindowSize`) is
///   [ProviderErrorKind.contextOverflow]; refusals and guardrail violations
///   end with `Finish(refusal / contentFilter)`. The iOS 27 error types
///   (`LanguageModelError`, …) are not in the iOS 26 SDK the app builds with.
/// * Usage is not reported (no [UsageUpdate]): `LanguageModelSession.usage`
///   is iOS 27 SDK API.
/// * Background: the system model runs out of process, so generation is NOT
///   paused on resign-active; background requests may be rate limited
///   ([ProviderErrorKind.rateLimited], retryable) and prewarm is skipped.
final class AppleFoundationModelsProvider implements ModelProvider {
  AppleFoundationModelsProvider({
    AppleMlBackend? backend,
    this.id = 'apple_fm',
    this.displayName = 'Apple Intelligence (on device)',
    this.config = const FmProviderConfig(),
    IdGenerator? ids,
  }) : backend = backend ?? AppleMl.backend,
       _ids = ids ?? RandomIdGenerator() {
    _router = EventRouter.acquire(this.backend);
  }

  /// The only model id: the default system model.
  static const String systemModelId = 'apple-system';

  final AppleMlBackend backend;
  final String id;
  final String displayName;
  final FmProviderConfig config;
  final IdGenerator _ids;
  final SerialQueue _queue = SerialQueue();
  final HistoryPlanner _planner = HistoryPlanner(appendShape: AppendShape.singleUserPrompt);
  final Map<String, _FmTurn> _turns = {};
  late final EventRouter _router;
  ({AppleMlAvailability status, int? contextSize, DateTime at})? _status;

  /// Is the system model usable now?
  ///
  /// * unsupported: not iOS, iOS < 26, an SDK without FoundationModels, or
  ///   `deviceNotEligible`;
  /// * downloadable: `appleIntelligenceNotEnabled` (the user can switch it on
  ///   in Settings, then the system downloads the model) or `modelNotReady`
  ///   (downloading, or other system reasons);
  /// * available: otherwise (`details.contextSize`, `details.localeSupported`).
  static Future<AppleMlAvailability> status({AppleMlBackend? backend}) async =>
      (await _fetchStatus(backend ?? AppleMl.backend)).$1;

  static Future<(AppleMlAvailability, int?)> _fetchStatus(AppleMlBackend b) async {
    if (!b.isSupported) {
      return (
        const AppleMlAvailability(
          AppleMlStatus.unsupported,
          AppleMlReason.notIos,
          'Apple Intelligence models run on iPhone, iPad and Mac only.',
        ),
        null,
      );
    }
    final a = await b.fmAvailability();
    final details = {'contextSize': a.contextSize, 'localeSupported': a.localeSupported};
    if (a.available) {
      return (
        AppleMlAvailability.available(
          message: a.localeSupported ? 'Ready.' : 'Ready, but the current language is not supported by the model.',
          details: details,
        ),
        a.contextSize,
      );
    }
    final verdict = switch (a.reason) {
      AmFmUnavailableReason.osTooOld => const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.osTooOld,
        'Needs iOS 26 or later.',
      ),
      AmFmUnavailableReason.frameworkMissing => const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.notCompiled,
        'This build of Sherpa was made without Foundation Models.',
      ),
      AmFmUnavailableReason.deviceNotEligible => const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.deviceNotEligible,
        'This device does not support Apple Intelligence.',
      ),
      AmFmUnavailableReason.appleIntelligenceNotEnabled => const AppleMlAvailability(
        AppleMlStatus.downloadable,
        AppleMlReason.appleIntelligenceNotEnabled,
        'Turn on Apple Intelligence in Settings to use this model.',
      ),
      AmFmUnavailableReason.modelNotReady => const AppleMlAvailability(
        AppleMlStatus.downloadable,
        AppleMlReason.modelNotReady,
        'The Apple Intelligence model is not ready yet (it may still be downloading).',
      ),
      AmFmUnavailableReason.none || AmFmUnavailableReason.unknown => const AppleMlAvailability(
        AppleMlStatus.unsupported,
        AppleMlReason.unknown,
        'Apple Intelligence is unavailable for an unknown reason.',
      ),
    };
    return (verdict, a.contextSize);
  }

  Future<({AppleMlAvailability status, int? contextSize, DateTime at})> _currentStatus() async {
    final s = _status;
    if (s != null && DateTime.now().difference(s.at) < config.statusTtl) return s;
    final (status, ctx) = await _fetchStatus(backend);
    return _status = (status: status, contextSize: ctx, at: DateTime.now());
  }

  @override
  ProviderInfo get info => ProviderInfo(
    id: id,
    kind: ProviderKind.localSystem,
    displayName: displayName,
    location: ExecutionLocation.onDevice,
  );

  ModelCapabilities _caps(int? contextSize) => ModelCapabilities(
    contextLength: contextSize ?? 4096,
    // Arguments are generated under the tool's GenerationSchema.
    toolCallFormat: ToolCallFormat.native,
    parallelToolCalls: true,
    tokenizerFamily: 'apple-fm',
    historyPolicy: HistoryPolicy.appendOnly,
  );

  @override
  Future<List<ModelDescriptor>> listModels() async {
    final s = backend.isSupported ? await _currentStatus() : null;
    if (s == null || s.status.status == AppleMlStatus.unsupported) return const [];
    return [
      ModelDescriptor(
        id: systemModelId,
        providerId: id,
        displayName: 'Apple on-device model',
        capabilities: _caps(s.contextSize),
        description: s.status.isAvailable ? null : s.status.message,
      ),
    ];
  }

  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    if (!backend.isSupported) return _caps(null);
    return _caps((await _currentStatus()).contextSize);
  }

  /// `LanguageModelSession.prewarm` for a likely next request ("only when
  /// you have a window of at least 1 second"; skipped in the background).
  ///
  /// Swift keeps the warmed session for the next request that starts a new
  /// native session with the same [instructions], no history and no tools
  /// (once); a request with tools builds its own session, so for it this
  /// can at most leave the model assets loaded.
  Future<void> prewarm({String? instructions}) async {
    if (backend.isSupported) await backend.fmPrewarm(instructions);
  }

  /// Forgets a conversation's native session (and any suspended tool turn).
  Future<void> forgetConversation(String sessionId) async {
    _planner.invalidate(sessionId);
    final t = _turns.remove(sessionId);
    if (t != null) await t.dispose(this, cancelNative: true);
    if (backend.isSupported) await backend.dropSession(AmEngine.foundationModels, sessionId);
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _FmRun(this, request, cancel).controller.stream;

  Future<void> dispose() async {
    for (final t in [..._turns.values]) {
      await t.dispose(this, cancelNative: true);
    }
    _turns.clear();
    await _router.release();
  }
}

/// A request mapped for Foundation Models.
@immutable
final class FmMappedRequest {
  const FmMappedRequest(
    this.instructions,
    this.messages,
    this.tools,
    this.responseSchemaJson,
    this.configKey,
    this.notices,
  );

  final String? instructions;
  final List<AmWireMessage> messages;
  final List<AmFmTool> tools;
  final String? responseSchemaJson;

  /// Instructions + tool set: `LanguageModelSession` fixes both at init.
  final String configKey;
  final List<ProviderNotice> notices;
}

FmMappedRequest mapFmRequest(ModelRequest request, FmProviderConfig config) {
  final notices = <ProviderNotice>[];
  final messages = WireMapper.mergeForSinglePrompt(const WireMapper().map(request.messages, notices: notices));
  final p = request.params;
  final tools = <AmFmTool>[];
  if (request.tools.isNotEmpty && p.toolChoice is! ToolChoiceNone) {
    final offered = request.tools.take(config.maxTools).toList();
    if (request.tools.length > offered.length) {
      notices.add(
        ProviderNotice(
          'tools_truncated',
          'Apple Intelligence gets at most ${config.maxTools} tools; ${request.tools.length - offered.length} were left out.',
          data: {
            'dropped': [for (final t in request.tools.skip(config.maxTools)) t.name],
          },
        ),
      );
    }
    for (final t in offered) {
      final r = FmSchemaConverter().convert(t.inputSchema, rootName: t.name);
      if (r.warnings.isNotEmpty) {
        notices.add(
          ProviderNotice(
            'fm_schema_lossy',
            'Tool "${t.name}": parts of its schema cannot be expressed.',
            data: {'tool': t.name, 'warnings': r.warnings},
          ),
        );
      }
      tools.add(AmFmTool(name: t.name, summary: t.description, schemaJson: r.encode()));
    }
    if (p.toolChoice is ToolChoiceRequired || p.toolChoice is ToolChoiceSpecific) {
      notices.add(
        const ProviderNotice('tool_choice_unsupported', 'Apple Intelligence cannot be forced to call a tool.'),
      );
    }
  }
  String? schemaJson;
  if (p.jsonSchema != null) {
    final r = FmSchemaConverter().convert(p.jsonSchema!, rootName: 'Response');
    if (r.warnings.isNotEmpty) {
      notices.add(
        ProviderNotice(
          'fm_schema_lossy',
          'Parts of the response schema cannot be expressed.',
          data: {'warnings': r.warnings},
        ),
      );
    }
    schemaJson = r.encode();
  }
  if (p.stop.isNotEmpty) notices.add(const ProviderNotice('stop_unsupported', 'Stop sequences are not supported.'));
  final system = request.systemPrompt?.trim() ?? '';
  final instructions = system.isEmpty ? null : request.systemPrompt;
  final configKey = configFingerprint({
    'instructions': instructions,
    'tools': [
      for (final t in tools) [t.name, t.summary, t.schemaJson],
    ],
  });
  return FmMappedRequest(instructions, messages, tools, schemaJson, configKey, notices);
}

/// A native generation that may span several Dart streams (one per tool
/// round trip).
final class _FmTurn {
  _FmTurn(this.generationId, this.sessionKey, this.route, this.configKey) : gate = CreditGate(route);

  final String generationId;
  final String sessionKey;
  final String configKey;
  final GenerationRoute route;
  final CreditGate gate;
  _FmRun? attached;
  final List<AmEventBatch> backlog = [];

  /// Calls reported to Dart and not yet answered.
  final Map<String, ToolCall> openCalls = {};

  /// What the native transcript holds before [produced] (the request that
  /// started or last resumed the turn).
  List<AmWireMessage> sent = const [];

  /// The assistant message the last detached stream produced.
  AmWireMessage? produced;
  bool ended = false;
  Timer? expiry;

  void onBatch(AmEventBatch batch) {
    final a = attached;
    if (a == null) {
      backlog.add(batch);
    } else {
      a.handleBatch(batch);
    }
  }

  void onError(Object error) {
    final a = attached;
    if (a != null) a.fail(error);
    ended = true;
  }

  /// Does [wire] continue this turn: the same history, the assistant message
  /// that asked for the tools, then a result for every open call?
  List<AmToolResult>? resultsFor(List<AmWireMessage> wire) {
    final p = produced;
    if (ended || p == null || openCalls.isEmpty) return null;
    final head = sent.length + 1;
    if (wire.length <= head) return null;
    for (var i = 0; i < sent.length; i++) {
      if (wireFingerprint(sent[i]) != wireFingerprint(wire[i])) return null;
    }
    if (wireFingerprint(wire[sent.length]) != wireFingerprint(p)) return null;
    final results = <AmToolResult>[];
    final answered = <String>{};
    for (final m in wire.sublist(head)) {
      final callId = m.toolCallId;
      if (m.role != 'tool' || callId == null || !openCalls.containsKey(callId)) return null;
      answered.add(callId);
      results.add(AmToolResult(callId: callId, output: m.content, isError: m.content.startsWith('[tool error]')));
    }
    return answered.length == openCalls.length ? results : null;
  }

  Future<void> dispose(AppleFoundationModelsProvider p, {required bool cancelNative}) async {
    expiry?.cancel();
    if (cancelNative && !ended) {
      ended = true;
      await p.backend.cancel(generationId).catchError((Object _) {});
    }
    route.close();
  }
}

/// One `stream()` call.
final class _FmRun {
  _FmRun(this.p, this.request, this.cancel) {
    controller = StreamController<ModelEvent>(
      onListen: () => unawaited(_run()),
      onPause: () {
        _subscriberPaused = true;
        _turn?.gate.hold();
      },
      onResume: () {
        _subscriberPaused = false;
        _turn?.gate.release();
      },
      onCancel: () {
        _listenerGone = true;
        _requestCancel();
      },
    );
  }

  final AppleFoundationModelsProvider p;
  final ModelRequest request;
  final CancellationToken? cancel;
  late final StreamController<ModelEvent> controller;

  _FmTurn? _turn;
  List<AmWireMessage> _wire = const [];
  final StringBuffer _answer = StringBuffer();
  final List<ToolCall> _calls = [];
  int _nextIndex = 0;
  Timer? _settle;
  Timer? _grace;
  Completer<void>? _done;
  bool _subscriberPaused = false;
  bool _listenerGone = false;
  bool _cancelRequested = false;
  bool _finishSent = false;
  bool _ephemeral = false;
  String _configKey = '';

  bool get _cancelled => cancel?.isCancelled ?? false;

  void _emit(ModelEvent e) {
    if (_listenerGone || controller.isClosed) return;
    if (e is Finish) {
      if (_finishSent) return;
      _finishSent = true;
    }
    controller.add(e);
  }

  Future<void> _run() async {
    try {
      await p._queue.run(_job, cancel: cancel);
    } on CancelledException {
      _emit(const Finish(FinishReason.cancelled));
    } on ProviderException catch (e) {
      _failNow(e);
    } on Object catch (e) {
      _failNow(appleMlErrorFrom(e, providerId: p.id));
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  void _failNow(ProviderException e) {
    if (_listenerGone || controller.isClosed) return;
    if (_cancelled) {
      _emit(const Finish(FinishReason.cancelled));
      return;
    }
    controller.addError(e);
  }

  /// A channel error while attached.
  void fail(Object error) {
    final d = _done;
    if (d != null && !d.isCompleted) d.completeError(appleMlErrorFrom(error, providerId: p.id));
  }

  Future<void> _job() async {
    cancel?.throwIfCancelled();
    if (!p.backend.isSupported) {
      throw ProviderException(
        ProviderErrorKind.unsupported,
        'Apple Intelligence models need iOS 26 or later.',
        providerId: p.id,
      );
    }
    final status = await p._currentStatus();
    if (!status.status.isAvailable) {
      p._status = null; // re-check next time: it may become ready
      throw ProviderException(ProviderErrorKind.unsupported, status.status.message, providerId: p.id);
    }
    final mapped = mapFmRequest(request, p.config);
    mapped.notices.forEach(_emit);
    _wire = mapped.messages;
    _configKey = mapped.configKey;
    final sessionId = request.cache.sessionId;
    _ephemeral = sessionId == null;

    // A suspended tool turn for this session: resume it or let it go.
    if (sessionId != null) {
      final waiting = p._turns[sessionId];
      if (waiting != null) {
        final results = waiting.configKey == mapped.configKey ? waiting.resultsFor(_wire) : null;
        if (results != null) return _resume(waiting, results);
        p._turns.remove(sessionId);
        await waiting.dispose(p, cancelNative: true);
        p._planner.invalidate(sessionId);
        _emit(
          const ProviderNotice(
            'fm_tool_turn_abandoned',
            'The pending tool call was not answered by this request; the session was rebuilt.',
          ),
        );
      }
    }

    final sessionKey = sessionId ?? 'oneoff:${p._ids.next('fmsession')}';
    for (var attempt = 0; ; attempt++) {
      final generationId = p._ids.next('fmgen');
      final plan = p._planner.plan(sessionKey: sessionKey, configKey: mapped.configKey, messages: _wire);
      var history = plan.history;
      var prompt = plan.pending.isEmpty ? '' : plan.pending.last.content;
      final synthetic =
          plan.mode == AmHistoryMode.continueAssistant || (plan.pending.isNotEmpty && plan.pending.last.role != 'user');
      if (synthetic) {
        // FM can neither continue a partial reply nor answer bare tool output:
        // rebuild with everything and add a short user turn.
        history = _wire;
        prompt = p.config.continuePrompt;
        _emit(
          ProviderNotice(
            'fm_synthetic_prompt',
            'Apple Intelligence continues from a rebuilt session.',
            data: {'reason': plan.reason},
          ),
        );
      }
      final mode = plan.mode == AmHistoryMode.append && !synthetic ? AmHistoryMode.append : AmHistoryMode.rebuild;

      final route = p._router.open(generationId);
      // What the native transcript holds once the prompt is in.
      final turn = _turn = _FmTurn(generationId, sessionKey, route, mapped.configKey)
        ..sent = synthetic ? [..._wire, AmWireMessage(role: 'user', content: prompt)] : _wire;
      if (_subscriberPaused) turn.gate.hold();
      turn.attached = this;
      route.listen(turn.onBatch, onError: turn.onError);
      if (!_ephemeral) p._turns[sessionKey] = turn;
      final done = _done = Completer<void>();

      final s = request.params;
      try {
        await p.backend.fmGenerate(
          AmFmGenerateRequest(
            generationId: generationId,
            sessionKey: sessionKey,
            ephemeral: _ephemeral,
            mode: mode,
            instructions: mapped.instructions,
            history: mode == AmHistoryMode.append ? const [] : history,
            prompt: prompt,
            tools: mapped.tools,
            responseSchemaJson: mapped.responseSchemaJson,
            sampling: AmSampling()
              ..temperature = s.temperature
              ..topP = s.topP
              ..topK = s.topK
              ..maxTokens = s.maxOutputTokens
              ..seed = s.seed,
            greedy: s.temperature == 0,
          ),
        );
      } on Object catch (e) {
        _dropTurn(turn);
        p._planner.invalidate(sessionKey);
        // The native session Dart wanted to append to is gone: rebuild once.
        if (attempt == 0 && e is PlatformException && e.code == AppleMlErrorCode.sessionLost) continue;
        throw appleMlErrorFrom(e, providerId: p.id);
      }
      await _await(done);
      return;
    }
  }

  Future<void> _resume(_FmTurn turn, List<AmToolResult> results) async {
    turn.expiry?.cancel();
    _turn = turn;
    turn.openCalls.clear();
    turn.sent = _wire;
    turn.produced = null;
    final done = _done = Completer<void>();
    turn.attached = this;
    if (_subscriberPaused) {
      turn.gate.hold();
    } else {
      turn.gate.release();
    }
    try {
      await p.backend.fmSubmitToolResults(turn.generationId, results);
    } on Object catch (e) {
      _dropTurn(turn);
      p._planner.invalidate(turn.sessionKey);
      throw appleMlErrorFrom(e, providerId: p.id);
    }
    final backlog = [...turn.backlog];
    turn.backlog.clear();
    for (final b in backlog) {
      if (done.isCompleted) {
        turn.backlog.add(b);
      } else {
        handleBatch(b);
      }
    }
    await _await(done);
  }

  Future<void> _await(Completer<void> done) async {
    if (cancel != null) unawaited(cancel!.whenCancelled.then((_) => _requestCancel()));
    if (_listenerGone) _requestCancel();
    try {
      await done.future;
    } on ProviderException {
      _endTurn(commit: false);
      rethrow;
    } finally {
      _settle?.cancel();
      _grace?.cancel();
    }
  }

  void _requestCancel() {
    final t = _turn;
    if (_cancelRequested || t == null || t.attached != this) return;
    _cancelRequested = true;
    unawaited(p.backend.cancel(t.generationId).catchError((Object _) {}));
    t.gate.release();
    _grace = Timer(p.config.cancelGrace, () {
      final d = _done;
      if (d != null && !d.isCompleted) {
        _emit(const Finish(FinishReason.cancelled));
        _endTurn(commit: false);
        d.complete();
      }
    });
  }

  /// Handles one batch of the attached turn.
  void handleBatch(AmEventBatch batch) {
    final t = _turn!;
    final done = _done!;
    var i = 0;
    for (; i < batch.events.length && !done.isCompleted && t.attached == this; i++) {
      _onEvent(batch.events[i]);
    }
    if (i < batch.events.length && t.attached == null && !t.ended) {
      // Detached mid-batch (not expected: detaching is timer-driven, between
      // batches): the rest belongs to the next stream.
      t.backlog.insert(
        0,
        AmEventBatch(generationId: batch.generationId, seq: batch.seq, events: batch.events.sublist(i)),
      );
      return;
    }
    t.gate.consumed(batch.seq);
  }

  void _onEvent(AmEvent e) {
    final done = _done!;
    switch (e.kind) {
      case AmEventKind.text:
        final text = e.text ?? '';
        if (text.isNotEmpty) {
          _answer.write(text);
          _emit(TextDelta(text));
        }
      case AmEventKind.toolRequest:
        final index = _nextIndex++;
        final callId = e.callId ?? 'fm_call_$index';
        final name = e.toolName ?? '';
        final raw = e.argumentsJson ?? '{}';
        final call = _parse(callId, name, raw);
        _calls.add(call);
        _turn!.openCalls[callId] = call;
        _emit(ToolCallStart(index: index, id: callId, name: name));
        _emit(ToolCallArgsDelta(index: index, fragment: raw));
        _emit(ToolCallComplete(index: index, call: call));
        _settle?.cancel();
        _settle = Timer(p.config.toolSettle, _detachForTools);
      case AmEventKind.info:
        final prompt = e.promptTokens ?? 0, cached = e.cachedPromptTokens ?? 0;
        _emit(
          UsageUpdate(
            Usage(
              inputTokens: prompt - cached,
              outputTokens: e.generationTokens ?? 0,
              cacheReadTokens: cached,
              reasoningTokens: e.reasoningTokens ?? 0,
            ),
          ),
        );
      case AmEventKind.notice:
        _emit(ProviderNotice(e.code ?? 'notice', e.message ?? ''));
      case AmEventKind.waiting:
        _emit(ProviderNotice('waiting', e.message ?? 'Waiting for the system model.', data: {'reason': e.code}));
      case AmEventKind.finished:
        _settle?.cancel();
        final reason = _cancelled ? FinishReason.cancelled : finishReasonForCode(e.code, sawToolCalls: false);
        _emit(Finish(reason, rawReason: e.code));
        _endTurn(commit: reason == FinishReason.stop || reason == FinishReason.length);
        done.complete();
      case AmEventKind.paused:
        _settle?.cancel();
        _emit(Finish(_cancelled ? FinishReason.cancelled : FinishReason.pause, rawReason: e.code));
        _endTurn(commit: false);
        done.complete();
      case AmEventKind.error:
        _settle?.cancel();
        _endTurn(commit: false);
        done.completeError(appleMlException(e.code, e.message, providerId: p.id));
      case AmEventKind.toolCall || AmEventKind.rejectedToolCall || AmEventKind.memoryWarning || AmEventKind.lifecycle:
        break;
    }
  }

  /// The model is waiting in `Tool.call`: end this stream so the agent loop
  /// can run the tools; the turn stays alive natively.
  void _detachForTools() {
    final t = _turn;
    final done = _done;
    if (t == null || done == null || done.isCompleted || t.attached != this) return;
    t.attached = null;
    t.produced = AmWireMessage(role: 'assistant', content: _answer.toString())
      ..toolCalls = [
        for (final c in _calls)
          AmToolCallWire(id: c.id, name: c.name, argumentsJson: WireMapper.argumentsForHistory(c)),
      ];
    t.gate.hold(); // nothing consumes until the next stream attaches
    t.expiry = Timer(p.config.toolResultTimeout, () {
      if (p._turns[t.sessionKey] == t) p._turns.remove(t.sessionKey);
      p._planner.invalidate(t.sessionKey);
      unawaited(t.dispose(p, cancelNative: true));
    });
    if (_ephemeral) {
      // Nobody can come back to a one-off request's tools.
      _dropTurn(t);
    }
    _emit(const Finish(FinishReason.toolCalls));
    done.complete();
  }

  void _endTurn({required bool commit}) {
    final t = _turn;
    if (t == null) return;
    t.ended = true;
    t.attached = null;
    if (p._turns[t.sessionKey] == t) p._turns.remove(t.sessionKey);
    t.route.close();
    t.expiry?.cancel();
    if (_ephemeral) return;
    if (commit) {
      p._planner.commit(
        t.sessionKey,
        _configKey,
        t.sent,
        AmWireMessage(role: 'assistant', content: _answer.toString()),
      );
    } else {
      p._planner.invalidate(t.sessionKey);
    }
  }

  void _dropTurn(_FmTurn t) {
    if (p._turns[t.sessionKey] == t) p._turns.remove(t.sessionKey);
    unawaited(t.dispose(p, cancelNative: true));
  }

  static ToolCall _parse(String id, String name, String raw) {
    try {
      final v = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
      if (v is Map) return ToolCall(id: id, name: name, arguments: v.cast<String, Object?>(), rawArguments: raw);
    } on FormatException {
      // fall through
    }
    return ToolCall(
      id: id,
      name: name,
      arguments: const {},
      rawArguments: raw,
      argumentsError: 'arguments must be a JSON object',
    );
  }
}

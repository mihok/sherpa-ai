import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../backend.dart';
import '../common/availability.dart';
import '../common/errors.dart';
import '../common/event_router.dart';
import '../common/foreground.dart';
import '../common/native_generation.dart';
import '../common/prompted_tools.dart';
import '../litert_lm/litert_lm_provider.dart' show LiteRtLmProvider;
import '../messages.pigeon.dart';
import 'nano_types.dart';
import 'prompt_renderer.dart';

/// Stop reason when the app leaves the foreground mid-reply.
const String kStopBackground = 'background';

/// [ModelProvider] for Gemini Nano through the ML Kit GenAI Prompt API
/// (AICore), `com.google.mlkit:genai-prompt:1.0.0-beta4`.
///
/// * One model, id [modelId]. [status] says whether it is available,
///   downloadable or unsupported; [download] fetches it with progress.
/// * Foreground only (R07 §1.5: AICore answers BACKGROUND_USE_BLOCKED in the
///   background, even from a foreground service). A request while Sherpa is
///   not on screen fails with [ProviderErrorKind.unsupported]
///   ([kNanoBackgroundMessage]); a reply running when the app leaves stops
///   at once and ends with `Finish(pause, rawReason: 'background')`, and the
///   continuation the agent loop then sends waits for the foreground.
/// * BUSY and the per-app battery quota are retryable (`overloaded`,
///   `rateLimited`, with AICore's suggested delay when given).
/// * Stateless: every request resends the full transcript
///   ([NanoPromptRenderer]); history policy `mutable`.
/// * Tools: prompted JSON format, parsed in Dart (no tool API in ML Kit).
/// * Limits: input under ~4000 tokens (`getTokenLimit`), output capped by
///   [GeminiNanoOptions.maxOutputTokens].
final class GeminiNanoProvider implements ModelProvider {
  GeminiNanoProvider({
    LiteRtBackend? backend,
    AppForeground? foreground,
    this.options = const GeminiNanoOptions(),
    this.id = 'gemini_nano',
    this.displayName = 'Gemini Nano (on-device)',
    this.cancelGrace = const Duration(seconds: 2),
  })  : backend = backend ?? SherpaLitert.backend,
        _foreground = foreground;

  /// The one model id this provider serves.
  static const String modelId = 'gemini-nano';

  final LiteRtBackend backend;
  final GeminiNanoOptions options;
  final String id;
  final String displayName;
  final Duration cancelGrace;

  AppForeground? _foreground;
  AppForeground get foreground => _foreground ??= WidgetsAppForeground();

  late final LiteRtEventRouter _router = LiteRtLmProvider.routerFor(backend);
  final TurnLock _lock = TurnLock();
  GeminiNanoInfo? _info;

  @override
  ProviderInfo get info =>
      ProviderInfo(id: id, kind: ProviderKind.localSystem, displayName: displayName, location: ExecutionLocation.onDevice);

  /// The last [status] answer.
  GeminiNanoInfo? get lastInfo => _info;

  /// Whether Gemini Nano can run here: available, downloadable,
  /// downloading, or unsupported with a reason. Never throws.
  Future<ProviderAvailability> status({bool refresh = true}) async {
    if (!backend.isSupported) {
      return const ProviderAvailability.unsupported('not_android', 'Gemini Nano runs on Android only.');
    }
    final NanoStatusMsg s;
    try {
      s = await backend.nanoStatus(options.config);
    } on MissingPluginException {
      return const ProviderAvailability.unsupported(
          'plugin_missing', 'The sherpa_litert plugin is not registered in this build.');
    } on Object catch (e) {
      return ProviderAvailability.unsupported('status_error', 'Could not ask AICore about Gemini Nano: $e');
    }
    final error = s.error;
    if (error != null) return _statusError(error);
    final info = _info = GeminiNanoInfo.fromMsg(s);
    final details = info.toJson();
    return switch (s.featureStatus) {
      NanoFeatureStatus.available => ProviderAvailability.available(
          reason: info.baseModelName == null ? 'Gemini Nano is ready.' : 'Gemini Nano (${info.baseModelName}) is ready.',
          details: details),
      NanoFeatureStatus.downloadable => ProviderAvailability(AvailabilityState.downloadable, 'downloadable',
          'Gemini Nano is supported on this device and can be downloaded.',
          details: details),
      NanoFeatureStatus.downloading => ProviderAvailability(
          AvailabilityState.downloading, 'downloading', 'Gemini Nano is being downloaded.',
          details: details),
      _ => ProviderAvailability.unsupported(
          'aicore_unavailable',
          'Gemini Nano is not supported on this device, or AICore has not fetched its configuration yet '
              '(this can take a while on a newly set-up phone).',
          details: details),
    };
  }

  ProviderAvailability _statusError(ErrorMsg e) {
    final details = {'errorCode': e.code, 'message': e.message};
    return switch (e.code) {
      NanoErrorCode.featureNotFound => ProviderAvailability.unsupported(
          'feature_not_found',
          'Gemini Nano is not available on this device (AICore reports FEATURE_NOT_FOUND; '
              'devices with an unlocked bootloader are not supported).',
          details: details),
      NanoErrorCode.bindingFailure => ProviderAvailability.unsupported(
          'aicore_binding_failed', 'Could not connect to AICore. Update AICore from Google Play and try again.',
          details: details),
      NanoErrorCode.needsSystemUpdate => ProviderAvailability.unsupported(
          'needs_system_update', 'Gemini Nano needs a system update on this device.',
          details: details),
      NanoErrorCode.aicoreIncompatible => ProviderAvailability.unsupported(
          'aicore_incompatible', 'The AICore version on this device is incompatible; update it from Google Play.',
          details: details),
      NanoErrorCode.notAvailable || NanoErrorCode.notSupported => ProviderAvailability.unsupported(
          'not_supported', 'Gemini Nano is not supported on this device.',
          details: details),
      _ => ProviderAvailability.unsupported('status_error', 'AICore reported an error: ${e.message}',
          details: details),
    };
  }

  /// Downloads Gemini Nano (AICore manages the file). Ends after
  /// [NanoDownloadCompleted] or [NanoDownloadFailed]; cancelling the
  /// subscription stops listening (AICore may finish the download anyway).
  Stream<NanoDownloadUpdate> download() {
    late final StreamController<NanoDownloadUpdate> out;
    NativeStream? native;
    StreamSubscription<LiteRtEvent>? sub;
    int? total;
    Future<void> run() async {
      if (!backend.isSupported) {
        out.add(NanoDownloadFailed(
            ProviderException(ProviderErrorKind.unsupported, 'Gemini Nano runs on Android only.', providerId: id)));
        await out.close();
        return;
      }
      final n = native = _router.open();
      sub = n.events.listen((e) {
        switch (e.kind) {
          case EventKind.downloadStarted:
            total = e.value;
            out.add(NanoDownloadStarted(e.value ?? 0));
          case EventKind.downloadProgress:
            out.add(NanoDownloadProgress(e.value ?? 0, totalBytes: total));
          case EventKind.downloadCompleted:
            _info = null;
            out.add(const NanoDownloadCompleted());
          case EventKind.downloadFailed:
            out.add(NanoDownloadFailed(nanoError(
                e.error ?? ErrorMsg(source: 'host', code: -1, message: 'download failed'),
                providerId: id)));
          case EventKind.cancelled:
            break;
          default:
            break;
        }
      }, onDone: () => unawaited(out.close()));
      try {
        await backend.nanoDownload(n.id, options.config);
      } on Object catch (e) {
        out.add(NanoDownloadFailed(hostError(e, providerId: id, nano: true)));
        n.abandon();
      }
    }

    out = StreamController<NanoDownloadUpdate>(
      onListen: () => unawaited(run()),
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        final n = native;
        if (n != null) {
          unawaited(backend.cancel(n.id, kStopUser).catchError((Object _) {}));
          n.abandon();
        }
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  /// Loads the model into AICore ahead of the first request (optional).
  Future<void> warmup() async {
    if (!backend.isSupported) return;
    try {
      await backend.nanoWarmup(options.config);
    } on Object catch (e) {
      throw hostError(e, providerId: id, nano: true);
    }
  }

  @override
  Future<List<ModelDescriptor>> listModels() async {
    final s = await status();
    if (s.state == AvailabilityState.unsupported) return const [];
    return [
      ModelDescriptor(
        id: modelId,
        providerId: id,
        displayName: _info?.baseModelName == null ? 'Gemini Nano' : 'Gemini Nano (${_info!.baseModelName})',
        capabilities: _capabilities(),
        description: s.reason,
      ),
    ];
  }

  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    if (_info == null && backend.isSupported) await status();
    return _capabilities();
  }

  ModelCapabilities _capabilities() {
    final input = _info?.tokenLimit ?? options.fallbackInputTokenLimit;
    return ModelCapabilities(
      // AICore limits input (~4000 tokens) and output separately; the core
      // budgets input = contextLength − output reserve, so add the cap.
      contextLength: input + options.maxOutputTokens,
      maxOutputTokens: options.maxOutputTokens,
      toolCallFormat: options.toolCalling ? ToolCallFormat.prompted : ToolCallFormat.none,
      parallelToolCalls: false,
      vision: options.vision,
      reasoning: _info?.thinking == true ? ReasoningSupport.optional : ReasoningSupport.none,
      // Gemini Nano uses a SentencePiece vocabulary like Gemma's: the closest
      // calibrated family for the core's estimator (counts are estimates).
      tokenizerFamily: 'gemma',
      supportsSystemRole: true,
      supportsPromptCache: false,
      historyPolicy: HistoryPolicy.mutable,
    );
  }

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _NanoGeneration(this, request, cancel).controller.stream;

  /// True when [request] continues a reply that was paused (the agent loop's
  /// follow-up after `Finish(pause)`).
  static bool continuesPausedReply(ModelRequest request) {
    final last = request.messages.isEmpty ? null : request.messages.last;
    return last != null && last.role == Role.assistant && last.finishReason == FinishReason.pause.name;
  }

  /// Flutter's lifecycle decides (resumed/inactive = foreground). AICore
  /// enforces "top app" itself; a request it still blocks fails with the
  /// same unsupported error.
  bool _isForeground() => foreground.isForeground;

  /// Waits for the foreground, then (up to ~1 s) for the OS to agree that
  /// Sherpa is the top app, so a resumed continuation does not race AICore.
  Future<void> _waitForeground() async {
    if (!foreground.isForeground) await foreground.changes.firstWhere((fg) => fg);
    for (var i = 0; i < 4; i++) {
      try {
        if (await backend.isAppInForeground()) return;
      } on Object {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// One `stream()` call.
final class _NanoGeneration extends NativeGeneration {
  _NanoGeneration(this.p, this.request, CancellationToken? cancel)
      : super(
          backend: p.backend,
          router: p._router,
          providerId: p.id,
          cancel: cancel,
          cancelGrace: p.cancelGrace,
          nano: true,
        );

  final GeminiNanoProvider p;
  final ModelRequest request;
  PromptedToolParser? _parser;
  bool _output = false;
  int _maxOutput = 0;
  StreamSubscription<bool>? _fgSub;

  @override
  Future<void> body() => p._lock.run(_turn);

  Future<void> _turn() async {
    if (listenerGone) throw const CancelledException();
    cancel?.throwIfCancelled();
    if (!p.backend.isSupported) {
      throw ProviderException(ProviderErrorKind.unsupported, 'Gemini Nano runs on Android only.', providerId: p.id);
    }
    if (!p._isForeground()) {
      if (!GeminiNanoProvider.continuesPausedReply(request)) {
        throw ProviderException(ProviderErrorKind.unsupported, kNanoBackgroundMessage, providerId: p.id);
      }
      emit(const ProviderNotice(
          'waiting_for_foreground', 'Gemini Nano continues this reply when Sherpa is back on screen.'));
      await guard(p._waitForeground());
    }
    var info = p._info;
    if (info == null || !info.available) {
      final s = await guard(p.status());
      info = p._info;
      if (!s.isAvailable || info == null) {
        throw ProviderException(
          s.state == AvailabilityState.unsupported ? ProviderErrorKind.unsupported : ProviderErrorKind.modelNotFound,
          s.canDownload || s.state == AvailabilityState.downloading
              ? 'Gemini Nano must be downloaded first (${s.reason})'
              : s.reason,
          providerId: p.id,
        );
      }
    }
    final rendered = NanoPromptRenderer(
      systemPromptSupported: info.systemPrompt ?? false,
      vision: p.options.vision,
      toolCalling: p.options.toolCalling,
    ).render(request);
    for (final n in rendered.notices) {
      emit(n);
    }
    if (rendered.promptedTools) _parser = PromptedToolParser(toolNames: rendered.toolNames);
    final params = request.params;
    final maxOut = params.maxOutputTokens == null || params.maxOutputTokens! > p.options.maxOutputTokens
        ? p.options.maxOutputTokens
        : params.maxOutputTokens!;
    _maxOutput = maxOut;
    final thinking = info.thinking == true && params.reasoning != null && params.reasoning != ReasoningEffort.off;

    // Foreground-only: leaving the app stops the reply at once.
    _fgSub = p.foreground.changes.listen((fg) {
      if (!fg) requestStop(kStopBackground);
    });
    try {
      await pump((streamId) => p.backend.nanoGenerate(NanoRequestMsg(
            streamId: streamId,
            config: p.options.config,
            systemInstruction: rendered.systemInstruction,
            prompt: rendered.prompt,
            images: rendered.images.isEmpty ? null : rendered.images,
            temperature: params.temperature,
            topK: params.topK,
            seed: params.seed,
            maxOutputTokens: maxOut,
            enableThinking: thinking,
            countTokens: p.options.countTokens,
          )));
    } finally {
      await _fgSub?.cancel();
    }
  }

  @override
  void onEvent(LiteRtEvent e) {
    switch (e.kind) {
      case EventKind.textDelta:
        final t = e.text ?? '';
        if (t.isEmpty) return;
        _output = true;
        _emitAll(_parser?.add(t) ?? [TextDelta(t)]);
      case EventKind.reasoningDelta:
        final t = e.text ?? '';
        if (t.isEmpty) return;
        _output = true;
        emit(ReasoningDelta(t));
      case EventKind.done:
        _emitAll(_parser?.finish() ?? const []);
        final s = e.stats;
        if (s != null && (s.promptTokens != null || s.outputTokens != null)) {
          emit(UsageUpdate(Usage(inputTokens: s.promptTokens ?? 0, outputTokens: s.outputTokens ?? 0)));
        }
        final calls = _parser?.toolCallCount ?? 0;
        final finish = s?.finishReason;
        final reason = calls > 0
            ? FinishReason.toolCalls
            : (finish == 1 || (s?.outputTokens != null && s!.outputTokens! >= _maxOutput))
                ? FinishReason.length
                : FinishReason.stop;
        emit(Finish(reason, rawReason: finish == null ? null : 'mlkit:$finish'));
      case EventKind.cancelled:
        if (userCancelled) {
          emit(const Finish(FinishReason.cancelled));
        } else {
          _emitAll(_parser?.finish() ?? const []);
          emit(Finish(FinishReason.pause, rawReason: e.detail ?? stopReason));
        }
      case EventKind.error:
        final err = e.error ?? ErrorMsg(source: 'host', code: -1, message: 'generation failed');
        if (err.source == 'nano' && err.code == NanoErrorCode.backgroundUseBlocked && _output) {
          // Left the foreground before Dart noticed: keep what was written.
          _emitAll(_parser?.finish() ?? const []);
          emit(const Finish(FinishReason.pause, rawReason: kStopBackground));
          return;
        }
        if (err.source == 'nano' && err.code == NanoErrorCode.cancelled) {
          emit(Finish(userCancelled ? FinishReason.cancelled : FinishReason.pause, rawReason: stopReason));
          return;
        }
        throw nanoError(err, providerId: p.id);
      default:
        break;
    }
  }

  void _emitAll(List<ModelEvent> events) {
    for (final m in events) {
      emit(m);
    }
  }
}

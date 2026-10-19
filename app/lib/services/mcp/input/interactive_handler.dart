/// The M5 [InputRequestHandler]: native elicitation forms, URL consent and
/// sampling approval, for both protocol eras (sherpa_mcp feeds MRTR input
/// requests and legacy server → client requests through the same calls).
library;

import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart' show Clock, SystemClock;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'elicitation_form.dart';
import 'host_settings.dart';
import 'input_history.dart';
import 'input_queue.dart';
import 'sampling.dart' show SamplingRateLimiter;

/// Queues every request for the user ([McpInputQueue]) and records how it
/// ended ([McpInputHistory]). Policy applied before anything is shown:
///
/// * **Form elicitation** asking for a secret (password, API key, token,
///   payment or bank details, one-time code) is refused at once with a
///   notice: servers MUST NOT request sensitive information in form mode
///   (client/elicitation.md; those go through URL mode, typed into the
///   service's own page).
/// * **URL elicitation** waits for consent; the UI opens the URL outside the
///   app and completes once the user is back (or a legacy
///   `notifications/elicitation/complete` names it).
/// * **Sampling** is refused unless the server's [McpSamplingMode] allows it
///   (off by default, and then not even declared), beyond the server's
///   requests-per-minute limit, and with tools (never declared). The
///   approval sheet is skipped only for a chat the user allowed ("Allow
///   for this chat", or [McpSamplingMode.allowInChats]); the answer is
///   always reviewed.
/// * **Roots** are refused (not declared on mobile).
final class InteractiveInputHandler implements InputRequestHandler {
  InteractiveInputHandler({
    required this.queue,
    required this.settings,
    required this.history,
    bool Function(String serverId)? isTrusted,
    Stream<McpElicitationCompleted> Function(String serverId)? completions,
    SamplingRateLimiter? limiter,
    Clock clock = const SystemClock(),
  })  : _isTrusted = isTrusted ?? ((_) => false),
        _completions = completions,
        _limiter = limiter ?? SamplingRateLimiter(clock: clock),
        _clock = clock;

  final McpInputQueue queue;
  final McpHostSettingsStore settings;
  final McpInputHistory history;
  final bool Function(String serverId) _isTrusted;
  final Stream<McpElicitationCompleted> Function(String serverId)? _completions;
  final SamplingRateLimiter _limiter;
  final Clock _clock;

  static const String rootsReason = 'Sherpa does not share folders with tool servers.';

  void _record(McpInputContext c, McpInputKind kind, McpInputOutcome outcome, String summary, {String? reason}) =>
      history.add(McpInputRecord(
        at: _clock.now(),
        serverId: c.serverId,
        kind: kind,
        outcome: outcome,
        summary: summary,
        toolName: c.origin?.toolName ?? c.originName,
        reason: reason,
      ));

  @override
  Future<McpElicitResult> elicit(McpElicitRequest request, McpInputContext context) async {
    switch (request.mode) {
      case McpElicitMode.form:
        final form = ElicitationForm.parse(request.requestedSchema ?? const {});
        final summary = McpInputHistory.formSummary(request, form);
        if (form.asksForSecret) {
          final what = form.secretReason!;
          _record(context, McpInputKind.form, McpInputOutcome.refused, summary, reason: 'asked for $what');
          queue.notice(McpInputNotice(
            serverId: context.serverId,
            serverName: context.serverName,
            message: '${context.serverName} asked for $what in a form. Sherpa refused: servers must not ask for '
                'passwords, keys or payment details that way.',
          ));
          return const McpElicitResult.decline();
        }
        final pending = queue.addForm(request, form, context, trusted: _isTrusted(context.serverId));
        final result = await pending.result;
        _record(context, McpInputKind.form, pending.outcome ?? McpInputOutcome.cancelled, summary);
        return result;
      case McpElicitMode.url:
        final pending = queue.addUrl(request, context, trusted: _isTrusted(context.serverId));
        StreamSubscription<McpElicitationCompleted>? sub;
        final id = request.elicitationId;
        if (id != null) {
          sub = _completions?.call(context.serverId).listen((c) {
            if (c.elicitationId == id) pending.complete();
          });
        }
        try {
          final result = await pending.result;
          _record(context, McpInputKind.url, pending.outcome ?? McpInputOutcome.cancelled,
              McpInputHistory.urlSummary(request));
          return result;
        } finally {
          await sub?.cancel();
        }
    }
  }

  @override
  Future<McpSamplingResult> createMessage(McpSamplingRequest request, McpInputContext context) async {
    final s = settings.of(context.serverId);
    Never refuse(String reason) {
      _record(context, McpInputKind.sampling, McpInputOutcome.refused, McpInputHistory.samplingSummary(request),
          reason: reason);
      throw InputRequestDeclined(reason);
    }

    if (!s.samplingDeclared) refuse('Using the model is turned off for this server in Sherpa.');
    if (request.usesTools) refuse('Sherpa does not give tools to tool servers that use its model.');
    if (!_limiter.tryAcquire(context.serverId, s.samplingPerMinute)) {
      refuse('This server asked to use the model too often (more than ${s.samplingPerMinute} a minute).');
    }
    final limits = SamplingLimits(
      maxTokens: request.maxTokens.clamp(1, s.samplingMaxTokens),
      requestedMaxTokens: request.maxTokens,
      requestedContext: request.includeContext,
    );
    final session = context.origin?.sessionId;
    final preApproved = session != null &&
        (s.sampling == McpSamplingMode.allowInChats || settings.chatAllowed(context.serverId, session));
    final pending = queue.addSampling(
      request,
      limits,
      context,
      trusted: _isTrusted(context.serverId),
      preApproved: preApproved,
    );
    if (session != null) {
      // "Allow for this chat" counts from the moment it is chosen, whether
      // or not this answer is sent.
      void grant() {
        if (pending.allowedForChat) settings.allowChat(context.serverId, session);
      }

      pending.addListener(grant);
    }
    try {
      final result = await pending.result;
      _record(
        context,
        McpInputKind.sampling,
        McpInputOutcome.accepted,
        McpInputHistory.samplingSummary(request,
            maxTokens: limits.maxTokens, model: pending.draft?.modelLabel, outputTokens: pending.draft?.outputTokens),
      );
      return result;
    } on InputRequestDeclined catch (e) {
      _record(context, McpInputKind.sampling, pending.outcome ?? McpInputOutcome.declined,
          McpInputHistory.samplingSummary(request, maxTokens: limits.maxTokens),
          reason: e.reason);
      rethrow;
    }
  }

  @override
  Future<List<McpRoot>> listRoots(McpInputContext context) async {
    _record(context, McpInputKind.roots, McpInputOutcome.refused, 'List folders', reason: rootsReason);
    throw const InputRequestDeclined(rootsReason);
  }
}

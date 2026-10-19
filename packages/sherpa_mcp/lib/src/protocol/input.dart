/// Server → client input: elicitation, sampling and roots, and the single
/// [InputRequestHandler] both eras feed (R01 §11).
///
/// Modern servers embed these as `inputRequests` in an `InputRequiredResult`
/// (basic/patterns/mrtr.md); legacy servers send them as JSON-RPC requests
/// on the response stream. The handler — native forms, the sampling
/// approval sheet, the URL-consent dialog — is written once.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show CancellationToken, FormatError, JsonMap, compact;

import '../era/era.dart';
import 'content.dart';
import 'json_read.dart';

/// Thrown by an [InputRequestHandler] when the user (or policy) refuses a
/// sampling or roots request. Elicitation is never declined this way: it
/// answers with [McpElicitAction.decline] / [McpElicitAction.cancel].
final class InputRequestDeclined implements Exception {
  const InputRequestDeclined([this.reason = 'declined by the user']);

  final String reason;

  @override
  String toString() => 'InputRequestDeclined: $reason';
}

/// Who a request was sent for: the chat and tool behind a `tools/call`.
///
/// [McpToolRouter] runs each call inside [run] (a zone value); the
/// connection captures [current] with every request it sends, so an
/// elicitation or sampling request the server makes while answering it can
/// be attributed to that chat (and a grant scoped to it) in BOTH eras: in
/// 2026-07-28 the input round runs inside the call itself; in the legacy
/// era the server's request names the request it relates to.
@immutable
final class McpCallOrigin {
  const McpCallOrigin({this.sessionId, this.toolName, this.fromApp = false});

  /// The chat (agent session) the call belongs to.
  final String? sessionId;

  /// Model-facing name of the tool that was called.
  final String? toolName;

  /// The call came from the server's MCP App view, not from the model.
  final bool fromApp;

  static final Object _zoneKey = Object();

  /// The origin of the code running now, if any.
  static McpCallOrigin? get current {
    final v = Zone.current[_zoneKey];
    return v is McpCallOrigin ? v : null;
  }

  /// Runs [body] with [origin] as [current].
  static Future<T> run<T>(McpCallOrigin origin, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: origin});

  @override
  String toString() => 'McpCallOrigin(${sessionId ?? '-'}, ${toolName ?? '-'}${fromApp ? ', app' : ''})';
}

/// Where an input request came from, for the consent UI.
@immutable
final class McpInputContext {
  const McpInputContext({
    required this.serverId,
    required this.serverName,
    required this.era,
    required this.cancel,
    this.originMethod,
    this.originName,
    this.origin,
  });

  /// The configured server (show it: "which server is asking" is a MUST).
  final String serverId;
  final String serverName;
  final McpEra era;

  /// The request this input belongs to (`tools/call`, `prompts/get`,
  /// `resources/read`, `tasks/get`), when known.
  final String? originMethod;

  /// The tool / prompt name or resource URI of that request, when known.
  final String? originName;

  /// The chat and tool the request was sent for, when known (see
  /// [McpCallOrigin]).
  final McpCallOrigin? origin;

  /// Fires when the originating request is cancelled; the UI should close.
  final CancellationToken cancel;
}

/// Elicitation mode (client/elicitation.md).
enum McpElicitMode { form, url }

/// `elicitation/create` params, form or URL mode.
@immutable
final class McpElicitRequest {
  const McpElicitRequest({
    required this.mode,
    required this.message,
    required this.raw,
    this.requestedSchema,
    this.url,
    this.elicitationId,
  });

  /// Throws [FormatError] for an unusable request: unknown mode, a form
  /// without an object `requestedSchema`, or a URL mode request whose URL
  /// is not absolute `https`/`http` (never open `javascript:`, `file:`,
  /// app schemes…).
  factory McpElicitRequest.fromJson(JsonMap p) {
    final modeRaw = asString(p['mode']) ?? 'form';
    final message = asString(p['message']) ?? '';
    switch (modeRaw) {
      case 'form':
        final schema = asMap(p['requestedSchema']);
        if (schema == null || schema['type'] != 'object') {
          throw const FormatError('form elicitation needs an object requestedSchema');
        }
        return McpElicitRequest(mode: McpElicitMode.form, message: message, requestedSchema: schema, raw: p);
      case 'url':
        final url = Uri.tryParse(asString(p['url']) ?? '');
        final scheme = url?.scheme.toLowerCase();
        if (url == null || !url.hasAuthority || (scheme != 'https' && scheme != 'http')) {
          throw const FormatError('URL elicitation needs an absolute http(s) URL');
        }
        return McpElicitRequest(
          mode: McpElicitMode.url,
          message: message,
          url: url,
          elicitationId: asString(p['elicitationId']),
          raw: p,
        );
      default:
        throw FormatError('unknown elicitation mode "$modeRaw"');
    }
  }

  final McpElicitMode mode;

  /// Untrusted server text.
  final String message;

  /// Form mode: the flat `{type:"object", properties, required?}` schema.
  final JsonMap? requestedSchema;

  /// URL mode: show it in full with the domain highlighted, ask consent,
  /// open it outside the app (Custom Tabs / SFSafariViewController), never
  /// prefetch it.
  final Uri? url;

  /// Legacy (2025-11-25) only; removed in 2026-07-28.
  final String? elicitationId;
  final JsonMap raw;
}

enum McpElicitAction { accept, decline, cancel }

/// `ElicitResult`. [content] only for an accepted form; values are
/// `string | number | boolean | string[]`.
@immutable
final class McpElicitResult {
  const McpElicitResult(this.action, {this.content});

  const McpElicitResult.accept([this.content]) : action = McpElicitAction.accept;

  const McpElicitResult.decline()
      : action = McpElicitAction.decline,
        content = null;

  const McpElicitResult.cancel()
      : action = McpElicitAction.cancel,
        content = null;

  final McpElicitAction action;
  final Map<String, Object?>? content;

  JsonMap toJson() => {
        'action': action.name,
        if (action == McpElicitAction.accept && content != null) 'content': content,
      };
}

/// One `SamplingMessage`; [content] is a single block or a list on the
/// wire, normalized to a list here.
@immutable
final class McpSamplingMessage {
  const McpSamplingMessage({required this.role, required this.content, this.meta});

  factory McpSamplingMessage.fromJson(JsonMap j) {
    final c = j['content'];
    return McpSamplingMessage(
      role: asString(j['role']) ?? 'user',
      content: McpContent.listFrom(c is List ? c : [c]),
      meta: asMap(j['_meta']),
    );
  }

  final String role;
  final List<McpContent> content;
  final JsonMap? meta;
}

/// `sampling/createMessage` params (client/sampling.md; deprecated in M).
@immutable
final class McpSamplingRequest {
  const McpSamplingRequest({
    required this.messages,
    required this.maxTokens,
    required this.raw,
    this.systemPrompt,
    this.includeContext,
    this.temperature,
    this.stopSequences = const [],
    this.modelPreferences,
    this.metadata,
    this.tools = const [],
    this.toolChoice,
  });

  /// Throws [FormatError] without `messages` or a positive `maxTokens`.
  factory McpSamplingRequest.fromJson(JsonMap p) {
    final maxTokens = asInt(p['maxTokens']);
    if (maxTokens == null || maxTokens <= 0) throw const FormatError('sampling needs a positive maxTokens');
    if (p['messages'] is! List) throw const FormatError('sampling needs messages');
    return McpSamplingRequest(
      messages: [for (final m in mapList(p['messages'])) McpSamplingMessage.fromJson(m)],
      maxTokens: maxTokens,
      systemPrompt: asString(p['systemPrompt']),
      includeContext: asString(p['includeContext']),
      temperature: asDouble(p['temperature']),
      stopSequences: stringList(p['stopSequences']),
      modelPreferences: asMap(p['modelPreferences']),
      metadata: asMap(p['metadata']),
      tools: mapList(p['tools']),
      toolChoice: asMap(p['toolChoice']),
      raw: p,
    );
  }

  final List<McpSamplingMessage> messages;

  /// The client MUST respect it.
  final int maxTokens;

  /// The client MAY ignore or alter [systemPrompt], [temperature],
  /// [stopSequences], [metadata] and [includeContext].
  final String? systemPrompt;
  final String? includeContext;
  final double? temperature;
  final List<String> stopSequences;

  /// `{hints?: [{name?}], costPriority?, speedPriority?, intelligencePriority?}`.
  final JsonMap? modelPreferences;
  final JsonMap? metadata;

  /// Tools in sampling (2025-11-25+); only when `sampling.tools` was declared.
  final List<JsonMap> tools;
  final JsonMap? toolChoice;
  final JsonMap raw;

  bool get usesTools => tools.isNotEmpty || toolChoice != null;
}

/// `CreateMessageResult`.
@immutable
final class McpSamplingResult {
  const McpSamplingResult({
    required this.content,
    required this.model,
    this.role = 'assistant',
    this.stopReason,
    this.meta,
  });

  /// `assistant`.
  final String role;
  final List<McpContent> content;

  /// The model that produced it (any identifier).
  final String model;

  /// `endTurn` | `stopSequence` | `maxTokens` | `toolUse` | other.
  final String? stopReason;
  final JsonMap? meta;

  JsonMap toJson() => compact({
        'role': role,
        'content': content.length == 1 ? content.single.toJson() : [for (final c in content) c.toJson()],
        'model': model,
        'stopReason': stopReason,
        '_meta': meta,
      });
}

/// A root (`file://` only). Deprecated in M; declared only when enabled.
@immutable
final class McpRoot {
  const McpRoot({required this.uri, this.name});

  final Uri uri;
  final String? name;

  JsonMap toJson() => compact({'uri': uri.toString(), 'name': name});
}

/// The host side of every server → client input request, for BOTH eras.
///
/// Implementations show which server is asking, offer decline/cancel and
/// let the user review answers (client/elicitation.md MUSTs). They are only
/// called for capabilities the connection declared.
abstract interface class InputRequestHandler {
  /// Form or URL elicitation. Return decline/cancel rather than throwing.
  ///
  /// URL mode: after consent, open the URL outside the app and complete
  /// with `accept` once the user is back (the browser tab closed): the
  /// request is retried right after.
  Future<McpElicitResult> elicit(McpElicitRequest request, McpInputContext context);

  /// Sampling. Throw [InputRequestDeclined] to refuse; the request then
  /// fails (M: the call is not retried; L: the server gets an error).
  Future<McpSamplingResult> createMessage(McpSamplingRequest request, McpInputContext context);

  /// Roots. Throw [InputRequestDeclined] to refuse.
  Future<List<McpRoot>> listRoots(McpInputContext context);
}

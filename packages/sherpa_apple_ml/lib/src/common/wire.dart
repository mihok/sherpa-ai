import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';

/// Maps core [Message]s onto the [AmWireMessage]s both native engines take.
///
/// Rules (shared by MLX and Foundation Models; FM applies
/// [mergeForSinglePrompt] on top):
/// * Text parts become `content`; embedded text resources and resource links
///   are inlined as text; images/audio are dropped with a notice (no VLM
///   path is wired: `MLXVLM` and FM attachments are out of scope).
/// * Reasoning is not replayed. Native sessions keep their own reasoning for
///   turns they produced (append mode); a rebuilt session starts without it,
///   which is what most templates do anyway (Qwen3 drops old thinking).
/// * Assistant tool calls keep the exact argument text the model produced
///   unless it was repaired or invalid (same rule as the llama.cpp mapper).
/// * Every [ToolResultPart] becomes its own `tool` message, in order, with
///   errors flagged in-band (`[tool error] …`) because templates have no
///   error field.
/// * A reply that was paused at a token boundary (`finishReason == pause`)
///   and the continuation that followed it are one assistant turn.
final class WireMapper {
  const WireMapper();

  List<AmWireMessage> map(List<Message> messages, {List<ProviderNotice>? notices}) {
    final out = <AmWireMessage>[];
    Message? pausedAssistant;
    for (final m in messages) {
      final mapped = mapMessage(m, notices: notices);
      if (m.role == Role.assistant && mapped.isNotEmpty) {
        final a = mapped.single;
        if (pausedAssistant != null && out.isNotEmpty && out.last.role == 'assistant') {
          final prev = out.removeLast();
          out.add(AmWireMessage(role: 'assistant', content: prev.content + a.content)..toolCalls = a.toolCalls);
        } else {
          out.add(a);
        }
        pausedAssistant = m.finishReason == FinishReason.pause.name && !m.hasToolCalls ? m : null;
        continue;
      }
      pausedAssistant = null;
      out.addAll(mapped);
    }
    return out;
  }

  List<AmWireMessage> mapMessage(Message m, {List<ProviderNotice>? notices}) {
    switch (m.role) {
      case Role.system:
        final text = m.text;
        return text.isEmpty ? const [] : [AmWireMessage(role: 'system', content: text)];
      case Role.user:
        final hasOther = m.content.any((c) => c is! ToolResultPart);
        return [
          ..._toolResults(m.toolResults),
          if (m.toolResults.isEmpty || hasOther) AmWireMessage(role: 'user', content: _userText(m, notices)),
        ];
      case Role.assistant:
        final calls = m.toolCalls;
        return [
          AmWireMessage(role: 'assistant', content: m.text)
            ..toolCalls = calls.isEmpty
                ? null
                : [
                    for (final c in calls)
                      AmToolCallWire(id: c.id, name: c.name, argumentsJson: argumentsForHistory(c)),
                  ],
        ];
      case Role.tool:
        return _toolResults(m.toolResults);
    }
  }

  String _userText(Message m, List<ProviderNotice>? notices) {
    final lines = <String>[];
    for (final c in m.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name):
          lines.add('[resource link${name == null ? '' : ' "$name"'}: $uri]');
        case MediaPart(:final mimeType):
          notices?.add(
            ProviderNotice(
              'content_dropped',
              'An attachment ($mimeType) was not sent: this on-device model takes text only.',
              data: {'kind': mimeType},
            ),
          );
        default:
          break;
      }
    }
    return lines.join('\n');
  }

  List<AmWireMessage> _toolResults(List<ToolResultPart> results) => [
    for (final r in results)
      AmWireMessage(role: 'tool', content: toolResultText(r))
        ..toolCallId = r.callId
        ..toolName = r.toolName,
  ];

  /// The argument text to send back for a call already in history.
  static String argumentsForHistory(ToolCall call) {
    final raw = call.rawArguments;
    if (raw == null || call.repaired || !call.isValid) return jsonEncode(call.arguments);
    return raw.trim().isEmpty ? '{}' : raw;
  }

  /// What the model sees of a tool result.
  static String toolResultText(ToolResultPart r) {
    final lines = <String>[];
    for (final c in r.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name, :final title, :final description):
          final label = title ?? name;
          lines.add(
            '[resource link${label == null ? '' : ' "$label"'}: $uri]${description == null ? '' : ' $description'}',
          );
        default:
          break;
      }
    }
    var text = lines.join('\n');
    if (text.isEmpty && r.structured != null) text = jsonEncode(r.structured);
    return r.isError ? '[tool error] $text' : text;
  }

  /// Foundation Models takes one prompt per turn and has no system role
  /// after the instructions: consecutive user messages are joined, and a
  /// mid-conversation system message becomes a user turn.
  static List<AmWireMessage> mergeForSinglePrompt(List<AmWireMessage> messages) {
    final out = <AmWireMessage>[];
    for (final m in messages) {
      final role = m.role == 'system' ? 'user' : m.role;
      final content = m.role == 'system' ? '[System note] ${m.content}' : m.content;
      if (role == 'user' && out.isNotEmpty && out.last.role == 'user') {
        final prev = out.removeLast();
        out.add(AmWireMessage(role: 'user', content: '${prev.content}\n\n$content'));
      } else {
        out.add(
          AmWireMessage(role: role, content: content)
            ..toolCalls = m.toolCalls
            ..toolCallId = m.toolCallId
            ..toolName = m.toolName,
        );
      }
    }
    return out;
  }
}

/// Content fingerprint of a wire message: equal fingerprints mean the
/// native engine would see the same turn.
String wireFingerprint(AmWireMessage m) {
  final canonical = jsonEncode([
    m.role,
    m.content,
    [
      for (final c in m.toolCalls ?? const <AmToolCallWire>[]) [c.id, c.name, c.argumentsJson],
    ],
    m.toolCallId,
    m.toolName,
  ]);
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Fingerprint of arbitrary JSON-able config (sorted keys).
String configFingerprint(Object? value) => sha256.convert(utf8.encode(jsonEncode(_sorted(value)))).toString();

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final x in v) _sorted(x)];
  return v;
}

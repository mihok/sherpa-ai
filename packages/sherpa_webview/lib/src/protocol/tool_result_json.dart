/// sherpa_core [ToolResult] → MCP `CallToolResult` JSON for the View.
library;

import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

/// Prefix of Sherpa's own attribution keys in `ToolResult.meta`; never
/// shown to a View.
const String sherpaMetaPrefix = 'ai.sherpa/';

/// Maps a core result to the MCP shape (`content`, `structuredContent`,
/// `isError`, `_meta`). Media that only exists as a local file URI is
/// dropped (a View must never learn device paths); reasoning, tool and UI
/// parts are app-side only.
Map<String, Object?> callToolResultJson(ToolResult r) => callToolResultFromParts(
      content: r.content,
      structured: r.structured,
      isError: r.isError,
      meta: r.meta,
    );

/// The same mapping for a stored [ToolResultPart].
Map<String, Object?> callToolResultFromPart(ToolResultPart p) =>
    callToolResultFromParts(content: p.content, structured: p.structured, isError: p.isError, meta: p.meta);

Map<String, Object?> callToolResultFromParts({
  required List<ContentPart> content,
  Map<String, Object?>? structured,
  bool isError = false,
  Map<String, Object?> meta = const {},
}) {
  final m = {
    for (final e in meta.entries)
      if (!e.key.startsWith(sherpaMetaPrefix)) e.key: e.value,
  };
  return {
    'content': [for (final c in content) ?contentBlockJson(c)],
    'structuredContent': ?structured,
    if (isError) 'isError': true,
    if (m.isNotEmpty) '_meta': m,
  };
}

/// One MCP content block, or null when the part has no View-safe form.
Map<String, Object?>? contentBlockJson(ContentPart c) => switch (c) {
      TextPart(:final text) => {'type': 'text', 'text': text},
      ImagePart(data: final d?, :final mimeType) => {'type': 'image', 'data': base64Encode(d), 'mimeType': mimeType},
      AudioPart(data: final d?, :final mimeType) => {'type': 'audio', 'data': base64Encode(d), 'mimeType': mimeType},
      ResourceLinkPart() => {
          'type': 'resource_link',
          'uri': c.uri,
          'name': c.name ?? c.uri,
          'title': ?c.title,
          'description': ?c.description,
          'mimeType': ?c.mimeType,
          'size': ?c.size,
        },
      EmbeddedResourcePart() => {
          'type': 'resource',
          'resource': {
            'uri': c.uri,
            'mimeType': ?c.mimeType,
            if (c.text != null) 'text': c.text else if (c.blob != null) 'blob': base64Encode(c.blob!) else 'text': '',
          },
        },
      _ => null,
    };

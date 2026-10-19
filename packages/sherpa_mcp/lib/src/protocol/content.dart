/// Content blocks (schema.ts `ContentBlock`, plus the sampling-only
/// `tool_use` / `tool_result` blocks) and resource contents.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart'
    show
        AudioPart,
        ContentPart,
        EmbeddedResourcePart,
        FormatError,
        ImagePart,
        JsonMap,
        ResourceLinkPart,
        TextPart,
        compact;

import 'json_read.dart';
import 'types.dart';

/// One content block. Every parsed block keeps its [raw] JSON so it can be
/// re-serialized losslessly (for example inside a sampling result) and so
/// unknown future fields survive.
@immutable
sealed class McpContent {
  const McpContent({this.annotations, this.meta, this.raw});

  /// Parses a block; an unknown `type` becomes [McpUnknownContent] and a
  /// known type with missing required fields throws [FormatError].
  factory McpContent.fromJson(JsonMap j) {
    final type = asString(j['type']);
    final annotations = McpAnnotations.tryParse(j['annotations']);
    final meta = asMap(j['_meta']);
    switch (type) {
      case 'text':
        return McpTextContent(reqString(j, 'text', 'text content'), annotations: annotations, meta: meta, raw: j);
      case 'image':
        return McpImageContent(
          data: reqString(j, 'data', 'image content'),
          mimeType: reqString(j, 'mimeType', 'image content'),
          annotations: annotations,
          meta: meta,
          raw: j,
        );
      case 'audio':
        return McpAudioContent(
          data: reqString(j, 'data', 'audio content'),
          mimeType: reqString(j, 'mimeType', 'audio content'),
          annotations: annotations,
          meta: meta,
          raw: j,
        );
      case 'resource_link':
        return McpResourceLink(
          uri: reqString(j, 'uri', 'resource_link'),
          name: asString(j['name']) ?? '',
          title: asString(j['title']),
          description: asString(j['description']),
          mimeType: asString(j['mimeType']),
          size: asInt(j['size']),
          icons: McpIcon.listFrom(j['icons']),
          annotations: annotations,
          meta: meta,
          raw: j,
        );
      case 'resource':
        return McpEmbeddedResource(
          McpResourceContents.fromJson(reqMap(j, 'resource', 'embedded resource')),
          annotations: annotations,
          meta: meta,
          raw: j,
        );
      case 'tool_use':
        return McpToolUseContent(
          id: reqString(j, 'id', 'tool_use'),
          name: reqString(j, 'name', 'tool_use'),
          input: asMap(j['input']) ?? const {},
          meta: meta,
          raw: j,
        );
      case 'tool_result':
        return McpToolResultContent(
          toolUseId: reqString(j, 'toolUseId', 'tool_result'),
          content: listFrom(j['content']),
          structuredContent: j['structuredContent'],
          isError: asBool(j['isError']) ?? false,
          meta: meta,
          raw: j,
        );
      default:
        return McpUnknownContent(j);
    }
  }

  /// Parses a list, keeping malformed blocks as [McpUnknownContent] so a
  /// result never silently loses a part.
  static List<McpContent> listFrom(Object? json) => [
        for (final e in asList(json))
          if (e is Map)
            _parseOrUnknown(e.cast<String, Object?>())
          else
            McpUnknownContent({'type': 'invalid', 'value': e}),
      ];

  static McpContent _parseOrUnknown(JsonMap j) {
    try {
      return McpContent.fromJson(j);
    } on FormatError {
      return McpUnknownContent(j);
    }
  }

  final McpAnnotations? annotations;
  final JsonMap? meta;

  /// The JSON this block was parsed from (null when built in Dart).
  final JsonMap? raw;

  String get type;

  JsonMap _build();

  JsonMap toJson() => raw ?? _build();

  /// Maps to Sherpa's provider-neutral [ContentPart]. Invalid base64 in
  /// media blocks degrades to a text note instead of throwing.
  ContentPart toContentPart();

  JsonMap _common(JsonMap m) => compact({...m, 'annotations': annotations?.toJson(), '_meta': meta});
}

final class McpTextContent extends McpContent {
  const McpTextContent(this.text, {super.annotations, super.meta, super.raw});

  final String text;

  @override
  String get type => 'text';

  @override
  JsonMap _build() => _common({'type': type, 'text': text});

  @override
  ContentPart toContentPart() => TextPart(text);
}

/// Base64 media (`image` / `audio`).
sealed class McpMediaContent extends McpContent {
  const McpMediaContent({required this.data, required this.mimeType, super.annotations, super.meta, super.raw});

  /// Base64 as sent by the server.
  final String data;
  final String mimeType;

  /// Decoded bytes, or null when [data] is not valid base64.
  Uint8List? get bytes {
    try {
      return base64.decode(data);
    } on FormatException {
      return null;
    }
  }

  @override
  JsonMap _build() => _common({'type': type, 'data': data, 'mimeType': mimeType});
}

final class McpImageContent extends McpMediaContent {
  const McpImageContent({required super.data, required super.mimeType, super.annotations, super.meta, super.raw});

  @override
  String get type => 'image';

  @override
  ContentPart toContentPart() {
    final b = bytes;
    return b == null ? const TextPart('[image with invalid data]') : ImagePart(mimeType: mimeType, data: b);
  }
}

final class McpAudioContent extends McpMediaContent {
  const McpAudioContent({required super.data, required super.mimeType, super.annotations, super.meta, super.raw});

  @override
  String get type => 'audio';

  @override
  ContentPart toContentPart() {
    final b = bytes;
    return b == null ? const TextPart('[audio with invalid data]') : AudioPart(mimeType: mimeType, data: b);
  }
}

/// `resource_link`: a pointer that need not appear in `resources/list`.
final class McpResourceLink extends McpContent {
  const McpResourceLink({
    required this.uri,
    required this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
    this.icons = const [],
    super.annotations,
    super.meta,
    super.raw,
  });

  final String uri;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;
  final List<McpIcon> icons;

  @override
  String get type => 'resource_link';

  @override
  JsonMap _build() => _common({
        'type': type,
        'uri': uri,
        'name': name,
        'title': title,
        'description': description,
        'mimeType': mimeType,
        'size': size,
        'icons': icons.isEmpty ? null : [for (final i in icons) i.toJson()],
      });

  @override
  ContentPart toContentPart() => ResourceLinkPart(
        uri: uri,
        name: name.isEmpty ? null : name,
        title: title,
        description: description,
        mimeType: mimeType,
        size: size,
      );
}

/// `resource`: an embedded [McpResourceContents].
final class McpEmbeddedResource extends McpContent {
  const McpEmbeddedResource(this.resource, {super.annotations, super.meta, super.raw});

  final McpResourceContents resource;

  @override
  String get type => 'resource';

  @override
  JsonMap _build() => _common({'type': type, 'resource': resource.toJson()});

  @override
  ContentPart toContentPart() => switch (resource) {
        final McpTextResourceContents t => EmbeddedResourcePart(uri: t.uri, mimeType: t.mimeType, text: t.text),
        final McpBlobResourceContents b =>
          EmbeddedResourcePart(uri: b.uri, mimeType: b.mimeType, blob: b.bytes ?? Uint8List(0)),
      };
}

/// Sampling only (2025-11-25+): the model asks to call a tool.
final class McpToolUseContent extends McpContent {
  const McpToolUseContent({required this.id, required this.name, required this.input, super.meta, super.raw});

  final String id;
  final String name;
  final JsonMap input;

  @override
  String get type => 'tool_use';

  @override
  JsonMap _build() => _common({'type': type, 'id': id, 'name': name, 'input': input});

  @override
  ContentPart toContentPart() => TextPart('[tool_use $name]');
}

/// Sampling only: the result of a [McpToolUseContent].
final class McpToolResultContent extends McpContent {
  const McpToolResultContent({
    required this.toolUseId,
    required this.content,
    this.structuredContent,
    this.isError = false,
    super.meta,
    super.raw,
  });

  final String toolUseId;
  final List<McpContent> content;
  final Object? structuredContent;
  final bool isError;

  @override
  String get type => 'tool_result';

  @override
  JsonMap _build() => _common({
        'type': type,
        'toolUseId': toolUseId,
        'content': [for (final c in content) c.toJson()],
        'structuredContent': structuredContent,
        'isError': isError ? true : null,
      });

  @override
  ContentPart toContentPart() => TextPart('[tool_result $toolUseId]');
}

/// A block whose `type` this client does not know, or a malformed block.
final class McpUnknownContent extends McpContent {
  const McpUnknownContent(JsonMap raw) : super(raw: raw);

  @override
  String get type => asString(raw!['type']) ?? 'unknown';

  @override
  JsonMap _build() => raw!;

  @override
  ContentPart toContentPart() => TextPart('[unsupported content: $type]');
}

/// `TextResourceContents` | `BlobResourceContents`.
@immutable
sealed class McpResourceContents {
  const McpResourceContents({required this.uri, this.mimeType, this.meta, this.raw});

  factory McpResourceContents.fromJson(JsonMap j) {
    final uri = reqString(j, 'uri', 'resource contents');
    final mimeType = asString(j['mimeType']);
    final meta = asMap(j['_meta']);
    final text = asString(j['text']);
    if (text != null) return McpTextResourceContents(uri: uri, mimeType: mimeType, text: text, meta: meta, raw: j);
    final blob = asString(j['blob']);
    if (blob != null) return McpBlobResourceContents(uri: uri, mimeType: mimeType, blob: blob, meta: meta, raw: j);
    throw const FormatError('resource contents need "text" or "blob"');
  }

  final String uri;
  final String? mimeType;

  /// Carries MCP Apps `_meta.ui` (csp, permissions, domain) on `ui://`
  /// contents (R03 §4); the Apps host reads it, this client only surfaces it.
  final JsonMap? meta;
  final JsonMap? raw;

  JsonMap toJson();
}

final class McpTextResourceContents extends McpResourceContents {
  const McpTextResourceContents({required super.uri, required this.text, super.mimeType, super.meta, super.raw});

  final String text;

  @override
  JsonMap toJson() => raw ?? compact({'uri': uri, 'mimeType': mimeType, 'text': text, '_meta': meta});
}

final class McpBlobResourceContents extends McpResourceContents {
  const McpBlobResourceContents({required super.uri, required this.blob, super.mimeType, super.meta, super.raw});

  /// Base64.
  final String blob;

  Uint8List? get bytes {
    try {
      return base64.decode(blob);
    } on FormatException {
      return null;
    }
  }

  @override
  JsonMap toJson() => raw ?? compact({'uri': uri, 'mimeType': mimeType, 'blob': blob, '_meta': meta});
}

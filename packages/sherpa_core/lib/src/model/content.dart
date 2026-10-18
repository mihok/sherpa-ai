import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../common/json.dart';
import 'tool.dart';

/// One piece of a message. The set mirrors what both remote APIs and MCP can
/// carry, so a tool result or a model reply can be stored losslessly and
/// re-rendered for any provider.
@immutable
sealed class ContentPart {
  const ContentPart();

  String get type;

  JsonMap toJson();

  static ContentPart fromJson(JsonMap j) {
    final type = j.req<String>('type');
    return switch (type) {
      'text' => TextPart.fromJson(j),
      'image' => ImagePart.fromJson(j),
      'audio' => AudioPart.fromJson(j),
      'resource_link' => ResourceLinkPart.fromJson(j),
      'resource' => EmbeddedResourcePart.fromJson(j),
      'reasoning' => ReasoningPart.fromJson(j),
      'tool_call' => ToolCallPart.fromJson(j),
      'tool_result' => ToolResultPart.fromJson(j),
      'ui' => UiResourcePart.fromJson(j),
      _ => UnknownPart(j),
    };
  }
}

final class TextPart extends ContentPart {
  const TextPart(this.text);

  factory TextPart.fromJson(JsonMap j) => TextPart(j.req<String>('text'));

  final String text;

  @override
  String get type => 'text';

  @override
  JsonMap toJson() => {'type': type, 'text': text};

  @override
  bool operator ==(Object other) => other is TextPart && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// Binary media is either inline [data] or a local [uri] (file:// in the app
/// sandbox). Large attachments are stored as files so the DB stays small.
abstract base class MediaPart extends ContentPart {
  const MediaPart({required this.mimeType, this.data, this.uri})
      : assert(data != null || uri != null, 'media needs data or uri');

  final String mimeType;
  final Uint8List? data;
  final Uri? uri;

  JsonMap mediaJson() => compact({
        'type': type,
        'mimeType': mimeType,
        'data': data == null ? null : base64Encode(data!),
        'uri': uri?.toString(),
      });

  static (String, Uint8List?, Uri?) readMedia(JsonMap j) {
    final d = j.opt<String>('data');
    final u = j.opt<String>('uri');
    return (
      j.req<String>('mimeType'),
      d == null ? null : base64Decode(d),
      u == null ? null : Uri.parse(u),
    );
  }
}

final class ImagePart extends MediaPart {
  const ImagePart({required super.mimeType, super.data, super.uri});

  factory ImagePart.fromJson(JsonMap j) {
    final (mime, data, uri) = MediaPart.readMedia(j);
    return ImagePart(mimeType: mime, data: data, uri: uri);
  }

  @override
  String get type => 'image';

  @override
  JsonMap toJson() => mediaJson();
}

final class AudioPart extends MediaPart {
  const AudioPart({required super.mimeType, super.data, super.uri});

  factory AudioPart.fromJson(JsonMap j) {
    final (mime, data, uri) = MediaPart.readMedia(j);
    return AudioPart(mimeType: mime, data: data, uri: uri);
  }

  @override
  String get type => 'audio';

  @override
  JsonMap toJson() => mediaJson();
}

/// A pointer to a resource (MCP `resource_link`) that the host may fetch.
final class ResourceLinkPart extends ContentPart {
  const ResourceLinkPart({
    required this.uri,
    this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
  });

  factory ResourceLinkPart.fromJson(JsonMap j) => ResourceLinkPart(
        uri: j.req<String>('uri'),
        name: j.opt<String>('name'),
        title: j.opt<String>('title'),
        description: j.opt<String>('description'),
        mimeType: j.opt<String>('mimeType'),
        size: j.optInt('size'),
      );

  final String uri;
  final String? name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;

  @override
  String get type => 'resource_link';

  @override
  JsonMap toJson() => compact({
        'type': type,
        'uri': uri,
        'name': name,
        'title': title,
        'description': description,
        'mimeType': mimeType,
        'size': size,
      });
}

/// Resource contents embedded inline (MCP `resource`): either text or blob.
final class EmbeddedResourcePart extends ContentPart {
  const EmbeddedResourcePart({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });

  factory EmbeddedResourcePart.fromJson(JsonMap j) {
    final b = j.opt<String>('blob');
    return EmbeddedResourcePart(
      uri: j.req<String>('uri'),
      mimeType: j.opt<String>('mimeType'),
      text: j.opt<String>('text'),
      blob: b == null ? null : base64Decode(b),
    );
  }

  final String uri;
  final String? mimeType;
  final String? text;
  final Uint8List? blob;

  @override
  String get type => 'resource';

  @override
  JsonMap toJson() => compact({
        'type': type,
        'uri': uri,
        'mimeType': mimeType,
        'text': text,
        'blob': blob == null ? null : base64Encode(blob!),
      });
}

/// Model reasoning ("thinking"). [signature] and [redactedData] are opaque
/// provider tokens that must be echoed back verbatim on the next request
/// (Anthropic rejects tool loops whose thinking blocks were altered).
final class ReasoningPart extends ContentPart {
  const ReasoningPart({
    required this.text,
    this.signature,
    this.redactedData,
    this.providerId,
  });

  factory ReasoningPart.fromJson(JsonMap j) => ReasoningPart(
        text: j.req<String>('text'),
        signature: j.opt<String>('signature'),
        redactedData: j.opt<String>('redactedData'),
        providerId: j.opt<String>('providerId'),
      );

  final String text;
  final String? signature;
  final String? redactedData;

  /// The provider that produced the opaque fields; other providers drop them.
  final String? providerId;

  bool get isRedacted => redactedData != null;

  @override
  String get type => 'reasoning';

  @override
  JsonMap toJson() => compact({
        'type': type,
        'text': text,
        'signature': signature,
        'redactedData': redactedData,
        'providerId': providerId,
      });
}

final class ToolCallPart extends ContentPart {
  const ToolCallPart(this.call);

  factory ToolCallPart.fromJson(JsonMap j) =>
      ToolCallPart(ToolCall.fromJson(j.obj('call')));

  final ToolCall call;

  @override
  String get type => 'tool_call';

  @override
  JsonMap toJson() => {'type': type, 'call': call.toJson()};
}

/// The outcome of one tool call. [content] is what the model sees;
/// [structured] carries MCP `structuredContent` for UIs and MCP Apps.
///
/// Results are DATA, never instructions: providers wrap them in a boundary
/// when rendering (see `PromptBoundary`).
final class ToolResultPart extends ContentPart {
  const ToolResultPart({
    required this.callId,
    required this.toolName,
    required this.content,
    this.structured,
    this.isError = false,
    this.uiResourceUri,
    this.durationMs,
  });

  factory ToolResultPart.fromJson(JsonMap j) => ToolResultPart(
        callId: j.req<String>('callId'),
        toolName: j.req<String>('toolName'),
        content: j.mapList('content').map(ContentPart.fromJson).toList(),
        structured: j.optObj('structured'),
        isError: j.opt<bool>('isError') ?? false,
        uiResourceUri: j.opt<String>('uiResourceUri'),
        durationMs: j.optInt('durationMs'),
      );

  final String callId;
  final String toolName;
  final List<ContentPart> content;
  final JsonMap? structured;
  final bool isError;

  /// Set when the tool declared an MCP Apps `ui://` resource for this result.
  final String? uiResourceUri;
  final int? durationMs;

  /// Concatenated text content, used for token estimates and plain fallbacks.
  String get text => content.whereType<TextPart>().map((p) => p.text).join('\n');

  ToolResultPart copyWith({List<ContentPart>? content, JsonMap? structured}) =>
      ToolResultPart(
        callId: callId,
        toolName: toolName,
        content: content ?? this.content,
        structured: structured ?? this.structured,
        isError: isError,
        uiResourceUri: uiResourceUri,
        durationMs: durationMs,
      );

  @override
  String get type => 'tool_result';

  @override
  JsonMap toJson() => compact({
        'type': type,
        'callId': callId,
        'toolName': toolName,
        'content': [for (final c in content) c.toJson()],
        'structured': structured,
        'isError': isError ? true : null,
        'uiResourceUri': uiResourceUri,
        'durationMs': durationMs,
      });
}

/// An MCP Apps view attached to a message (rendered by the apps host).
final class UiResourcePart extends ContentPart {
  const UiResourcePart({
    required this.resourceUri,
    required this.serverId,
    this.callId,
  });

  factory UiResourcePart.fromJson(JsonMap j) => UiResourcePart(
        resourceUri: j.req<String>('resourceUri'),
        serverId: j.req<String>('serverId'),
        callId: j.opt<String>('callId'),
      );

  final String resourceUri;
  final String serverId;
  final String? callId;

  @override
  String get type => 'ui';

  @override
  JsonMap toJson() => compact({
        'type': type,
        'resourceUri': resourceUri,
        'serverId': serverId,
        'callId': callId,
      });
}

/// Preserves parts written by a newer app version so data is never lost.
final class UnknownPart extends ContentPart {
  const UnknownPart(this.raw);

  final JsonMap raw;

  @override
  String get type => raw['type']?.toString() ?? 'unknown';

  @override
  JsonMap toJson() => raw;
}

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';

import 'attachment_store.dart';

/// Wraps a chat's [ModelProvider] so attachments stored as `file://`
/// references reach the model as bytes.
///
/// Providers are pure Dart and do no file IO: an [ImagePart] with only a
/// local `uri`, or an [EmbeddedResourcePart] that points at a stored PDF,
/// would be replaced by an "omitted" note in the request. This reads them
/// from the [ChatAttachmentStore] just before each request (never into
/// the transcript, which keeps only the reference). A file that is gone
/// becomes a short text note, so the model knows something was attached.
///
/// Only files inside the attachments folder are read ([ChatAttachmentStore.read]).
final class AttachmentInliningProvider implements ModelProvider {
  AttachmentInliningProvider(this.inner, this.store);

  final ModelProvider inner;
  final ChatAttachmentStore store;

  /// Recently read files: a tool loop re-sends the same history every step.
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  int _cachedBytes = 0;
  static const int _maxCacheBytes = 24 * 1024 * 1024;

  @override
  ProviderInfo get info => inner.info;

  @override
  Future<List<ModelDescriptor>> listModels() => inner.listModels();

  @override
  Future<ModelCapabilities> capabilities(String modelId) => inner.capabilities(modelId);

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) async* {
    final messages = await resolve(request.messages);
    yield* inner.stream(
      identical(messages, request.messages)
          ? request
          : ModelRequest(
              modelId: request.modelId,
              messages: messages,
              systemPrompt: request.systemPrompt,
              tools: request.tools,
              params: request.params,
              cache: request.cache,
            ),
      cancel: cancel,
    );
  }

  /// [messages] with every local attachment inlined (the same list when
  /// there is nothing to inline).
  Future<List<Message>> resolve(List<Message> messages) async {
    List<Message>? out;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (!m.content.any(_needsBytes)) continue;
      out ??= [...messages];
      out[i] = m.copyWith(content: [for (final part in m.content) await _inline(part)]);
    }
    return out ?? messages;
  }

  static bool _needsBytes(ContentPart p) => switch (p) {
    ImagePart(data: null, :final uri?) => uri.scheme == 'file',
    EmbeddedResourcePart(text: null, blob: null, :final uri) => Uri.tryParse(uri)?.scheme == 'file',
    ToolResultPart(:final content) => content.any(_needsBytes),
    _ => false,
  };

  Future<ContentPart> _inline(ContentPart p) async {
    switch (p) {
      case ImagePart(data: null, :final uri?, :final mimeType) when uri.scheme == 'file':
        final bytes = await _read(uri);
        return bytes == null
            ? TextPart('[An attached image is no longer on this device: ${uri.pathSegments.lastOrNull ?? 'image'}]')
            : ImagePart(mimeType: mimeType, data: bytes);
      case EmbeddedResourcePart(text: null, blob: null, :final uri, :final mimeType, :final pages):
        final parsed = Uri.tryParse(uri);
        if (parsed == null || parsed.scheme != 'file') return p;
        final bytes = await _read(parsed);
        return bytes == null
            ? TextPart('[An attached file is no longer on this device: ${parsed.pathSegments.lastOrNull ?? 'file'}]')
            : EmbeddedResourcePart(uri: uri, mimeType: mimeType, blob: bytes, size: bytes.length, pages: pages);
      case ToolResultPart(:final content) when content.any(_needsBytes):
        return p.copyWith(content: [for (final c in content) await _inline(c)]);
      default:
        return p;
    }
  }

  Future<Uint8List?> _read(Uri uri) async {
    final key = uri.toString();
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final bytes = await store.read(uri);
    if (bytes == null) return null;
    _cache[key] = bytes;
    _cachedBytes += bytes.length;
    while (_cachedBytes > _maxCacheBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cachedBytes -= _cache.remove(oldest)!.length;
    }
    return bytes;
  }
}

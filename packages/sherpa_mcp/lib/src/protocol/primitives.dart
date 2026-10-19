/// Server primitives: tools, resources, prompts, completion (server/*.md).
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart'
    show FormatError, JsonMap, ToolAnnotations, ToolDefinition, ToolResult, ToolSource, ToolSourceKind;

import 'content.dart';
import 'headers.dart';
import 'json_read.dart';
import 'types.dart';

/// A tool exactly as the server described it (server/tools.md §Tool).
///
/// [raw] is the untouched definition: the tool router pins
/// `sha256(name, description, inputSchema, outputSchema, annotations)` over
/// it and quarantines changed tools (R11 §9.7). Annotations are untrusted
/// hints unless the server is trusted.
@immutable
final class McpTool {
  const McpTool({
    required this.name,
    required this.inputSchema,
    required this.raw,
    this.title,
    this.description,
    this.outputSchema,
    this.annotations = const ToolAnnotations(),
    this.icons = const [],
    this.meta,
    this.headerParams = const [],
  });

  /// Throws [FormatError] for a definition the client must not use: no
  /// name, or an `inputSchema` whose root is not an object schema
  /// (`inputSchema` MUST be an object with `type: "object"`).
  factory McpTool.fromJson(JsonMap j) {
    final name = reqString(j, 'name', 'tool');
    if (name.isEmpty) throw const FormatError('tool: empty name');
    final schema = asMap(j['inputSchema']);
    if (schema == null) throw FormatError('tool "$name": inputSchema must be an object');
    if (schema['type'] != 'object') throw FormatError('tool "$name": inputSchema root must be type "object"');
    return McpTool(
      name: name,
      title: asString(j['title']),
      description: asString(j['description']),
      inputSchema: schema,
      outputSchema: asMap(j['outputSchema']),
      annotations: ToolAnnotations.fromJson(_annotationsOf(j['annotations'])),
      icons: McpIcon.listFrom(j['icons']),
      meta: asMap(j['_meta']),
      raw: j,
    );
  }

  static JsonMap _annotationsOf(Object? v) {
    final m = asMap(v);
    if (m == null) return const {};
    // Keep only well-typed hints; a wrong type must not throw.
    return {
      for (final k in const ['title', 'readOnlyHint', 'destructiveHint', 'idempotentHint', 'openWorldHint'])
        if (k == 'title' ? m[k] is String : m[k] is bool) k: m[k],
    };
  }

  final String name;
  final String? title;
  final String? description;
  final JsonMap inputSchema;
  final JsonMap? outputSchema;
  final ToolAnnotations annotations;
  final List<McpIcon> icons;
  final JsonMap? meta;
  final JsonMap raw;

  /// `x-mcp-header` declarations (2026-07-28 HTTP); mirrored as
  /// `Mcp-Param-*` headers on every call.
  final List<McpHeaderParam> headerParams;

  McpTool _withHeaderParams(List<McpHeaderParam> p) => McpTool(
        name: name,
        title: title,
        description: description,
        inputSchema: inputSchema,
        outputSchema: outputSchema,
        annotations: annotations,
        icons: icons,
        meta: meta,
        raw: raw,
        headerParams: p,
      );

  /// Display name precedence: `title`, `annotations.title`, `name`.
  String get displayName => title ?? annotations.title ?? name;

  JsonMap? get _ui => asMap(meta?['ui']);

  /// MCP Apps: the `ui://` resource rendered for this tool, from
  /// `_meta.ui.resourceUri`, falling back to the deprecated flat
  /// `_meta["ui/resourceUri"]` (R03 §3). A value that is not a `ui://` URI
  /// is ignored (the tool keeps working without UI).
  String? get uiResourceUri {
    final uri = _ui?['resourceUri'] ?? meta?['ui/resourceUri'];
    return uri is String && uri.startsWith('ui://') ? uri : null;
  }

  /// `_meta.ui.visibility`; null means the default `["model","app"]`.
  List<String>? get uiVisibility {
    final v = _ui?['visibility'];
    return v is List ? stringList(v) : null;
  }

  /// Spec predicate (not the SDK helper): hidden from the model unless the
  /// visibility includes `model`. `[]` is neither model- nor app-visible.
  bool get modelVisible => uiVisibility?.contains('model') ?? true;

  /// Whether an MCP App of the SAME server may call it (R03 §3).
  bool get appCallable => uiVisibility?.contains('app') ?? true;

  /// Convenience mapping to the core [ToolDefinition] under a
  /// router-chosen (namespaced) [modelName]; [wireName] stays [name].
  ToolDefinition toDefinition({required String modelName, required String serverId, String? serverName}) =>
      ToolDefinition(
        name: modelName,
        originalName: name,
        title: title,
        description: description ?? '',
        inputSchema: inputSchema,
        outputSchema: outputSchema,
        annotations: annotations,
        source: ToolSource(ToolSourceKind.mcp, serverId: serverId, serverName: serverName),
        uiResourceUri: uiResourceUri,
        modelVisible: modelVisible,
      );

  JsonMap toJson() => raw;

  @override
  String toString() => 'McpTool($name)';
}

/// Attaches the header scan to [tool], or returns the rejection reason.
(McpTool?, String?) withHeaderScan(McpTool tool) {
  final scan = scanMcpHeaderParams(tool.inputSchema);
  if (!scan.isValid) return (null, scan.invalidReason);
  return (scan.params.isEmpty ? tool : tool._withHeaderParams(scan.params), null);
}

/// A tool definition the client refused to expose, and why.
@immutable
final class McpToolRejection {
  const McpToolRejection(this.name, this.reason, this.raw);

  /// The name if one could be read, else `<unnamed>`.
  final String name;
  final String reason;
  final JsonMap raw;

  @override
  String toString() => 'McpToolRejection($name: $reason)';
}

/// `CallToolResult` (server/tools.md §Tool Result).
@immutable
final class McpCallToolResult {
  const McpCallToolResult({
    required this.content,
    required this.raw,
    this.structuredContent,
    this.isError = false,
    this.meta,
    this.taskId,
  });

  factory McpCallToolResult.fromJson(JsonMap j, {String? taskId}) => McpCallToolResult(
        content: McpContent.listFrom(j['content']),
        structuredContent: j['structuredContent'],
        isError: asBool(j['isError']) ?? false,
        meta: asMap(j['_meta']),
        raw: j,
        taskId: taskId,
      );

  final List<McpContent> content;

  /// Any JSON value in M; an object in L.
  final Object? structuredContent;

  /// A tool-level failure (bad input, API error): feed back to the model.
  final bool isError;
  final JsonMap? meta;
  final JsonMap raw;

  /// Set when the server ran the call as a Tasks-extension task.
  final String? taskId;

  /// MCP Apps: a result-level `_meta.ui.resourceUri` override, if any.
  String? get uiResourceUri {
    final uri = asMap(meta?['ui'])?['resourceUri'] ?? meta?['ui/resourceUri'];
    return uri is String && uri.startsWith('ui://') ? uri : null;
  }

  /// Maps to the core [ToolResult]; [toolUiResourceUri] is the tool's own
  /// `uiResourceUri` used when the result carries none.
  ToolResult toToolResult({String? toolUiResourceUri}) => ToolResult(
        content: [for (final c in content) c.toContentPart()],
        structured: structuredContent is Map ? (structuredContent! as Map).cast<String, Object?>() : null,
        isError: isError,
        uiResourceUri: uiResourceUri ?? toolUiResourceUri,
        meta: meta ?? const {},
      );
}

/// `Resource` (server/resources.md).
@immutable
final class McpResource {
  const McpResource({
    required this.uri,
    required this.name,
    required this.raw,
    this.title,
    this.description,
    this.mimeType,
    this.size,
    this.icons = const [],
    this.annotations,
    this.meta,
  });

  factory McpResource.fromJson(JsonMap j) => McpResource(
        uri: reqString(j, 'uri', 'resource'),
        name: asString(j['name']) ?? '',
        title: asString(j['title']),
        description: asString(j['description']),
        mimeType: asString(j['mimeType']),
        size: asInt(j['size']),
        icons: McpIcon.listFrom(j['icons']),
        annotations: McpAnnotations.tryParse(j['annotations']),
        meta: asMap(j['_meta']),
        raw: j,
      );

  final String uri;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;
  final List<McpIcon> icons;
  final McpAnnotations? annotations;

  /// May carry MCP Apps `_meta.ui` as a fallback for the read contents.
  final JsonMap? meta;
  final JsonMap raw;
}

/// `ResourceTemplate` (RFC 6570 `uriTemplate`).
@immutable
final class McpResourceTemplate {
  const McpResourceTemplate({
    required this.uriTemplate,
    required this.name,
    required this.raw,
    this.title,
    this.description,
    this.mimeType,
    this.icons = const [],
    this.annotations,
  });

  factory McpResourceTemplate.fromJson(JsonMap j) => McpResourceTemplate(
        uriTemplate: reqString(j, 'uriTemplate', 'resource template'),
        name: asString(j['name']) ?? '',
        title: asString(j['title']),
        description: asString(j['description']),
        mimeType: asString(j['mimeType']),
        icons: McpIcon.listFrom(j['icons']),
        annotations: McpAnnotations.tryParse(j['annotations']),
        raw: j,
      );

  final String uriTemplate;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final List<McpIcon> icons;
  final McpAnnotations? annotations;
  final JsonMap raw;
}

/// `ReadResourceResult`. An empty [contents] does NOT mean "not found"
/// (not-found is error -32602 in M, -32002 from L servers).
@immutable
final class McpReadResourceResult {
  const McpReadResourceResult({required this.contents, required this.raw, this.meta});

  factory McpReadResourceResult.fromJson(JsonMap j) => McpReadResourceResult(
        contents: [
          for (final c in mapList(j['contents']))
            ?_tryContents(c),
        ],
        meta: asMap(j['_meta']),
        raw: j,
      );

  static McpResourceContents? _tryContents(JsonMap c) {
    try {
      return McpResourceContents.fromJson(c);
    } on FormatError {
      return null;
    }
  }

  final List<McpResourceContents> contents;
  final JsonMap? meta;
  final JsonMap raw;
}

/// `Prompt` (server/prompts.md).
@immutable
final class McpPrompt {
  const McpPrompt({
    required this.name,
    required this.raw,
    this.title,
    this.description,
    this.arguments = const [],
    this.icons = const [],
    this.meta,
  });

  factory McpPrompt.fromJson(JsonMap j) => McpPrompt(
        name: reqString(j, 'name', 'prompt'),
        title: asString(j['title']),
        description: asString(j['description']),
        arguments: [
          for (final a in mapList(j['arguments']))
            if (asString(a['name']) case final n?)
              McpPromptArgument(
                name: n,
                title: asString(a['title']),
                description: asString(a['description']),
                required: asBool(a['required']) ?? false,
              ),
        ],
        icons: McpIcon.listFrom(j['icons']),
        meta: asMap(j['_meta']),
        raw: j,
      );

  final String name;
  final String? title;
  final String? description;
  final List<McpPromptArgument> arguments;
  final List<McpIcon> icons;
  final JsonMap? meta;
  final JsonMap raw;

  String get displayName => title ?? name;
}

@immutable
final class McpPromptArgument {
  const McpPromptArgument({required this.name, this.title, this.description, this.required = false});

  final String name;
  final String? title;
  final String? description;
  final bool required;
}

/// One prompt message: a single content block per message.
@immutable
final class McpPromptMessage {
  const McpPromptMessage({required this.role, required this.content});

  /// `user` or `assistant`.
  final String role;
  final McpContent content;
}

/// `GetPromptResult`.
@immutable
final class McpGetPromptResult {
  const McpGetPromptResult({required this.messages, required this.raw, this.description});

  factory McpGetPromptResult.fromJson(JsonMap j) => McpGetPromptResult(
        description: asString(j['description']),
        messages: [
          for (final m in mapList(j['messages']))
            if (asMap(m['content']) case final c?)
              McpPromptMessage(
                role: asString(m['role']) ?? 'user',
                content: McpContent.listFrom([c]).first,
              ),
        ],
        raw: j,
      );

  final String? description;
  final List<McpPromptMessage> messages;
  final JsonMap raw;
}

/// What `completion/complete` completes against.
@immutable
sealed class McpCompletionRef {
  const McpCompletionRef();

  JsonMap toJson();
}

final class McpPromptRef extends McpCompletionRef {
  const McpPromptRef(this.name);

  final String name;

  @override
  JsonMap toJson() => {'type': 'ref/prompt', 'name': name};
}

final class McpResourceTemplateRef extends McpCompletionRef {
  const McpResourceTemplateRef(this.uri);

  /// A resource template URI (`ref/resource`).
  final String uri;

  @override
  JsonMap toJson() => {'type': 'ref/resource', 'uri': uri};
}

/// `CompleteResult.completion` (≤ 100 values).
@immutable
final class McpCompletion {
  const McpCompletion({required this.values, this.total, this.hasMore = false});

  factory McpCompletion.fromJson(JsonMap j) {
    final c = asMap(j['completion']) ?? const {};
    final values = stringList(c['values']);
    return McpCompletion(
      values: values.length > 100 ? values.sublist(0, 100) : values,
      total: asInt(c['total']),
      hasMore: asBool(c['hasMore']) ?? false,
    );
  }

  final List<String> values;
  final int? total;
  final bool hasMore;
}

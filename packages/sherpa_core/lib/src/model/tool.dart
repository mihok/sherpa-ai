import 'package:meta/meta.dart';

import '../common/json.dart';

/// MCP tool annotations. All are HINTS from possibly untrusted servers: the
/// approval policy acts on them only for built-in tools and trusted servers
/// (`ApprovalPolicy.annotationsFor`); for anything else they are display
/// material.
@immutable
final class ToolAnnotations {
  const ToolAnnotations({
    this.title,
    this.readOnlyHint,
    this.destructiveHint,
    this.idempotentHint,
    this.openWorldHint,
  });

  factory ToolAnnotations.fromJson(JsonMap j) => ToolAnnotations(
        title: j.opt<String>('title'),
        readOnlyHint: j.opt<bool>('readOnlyHint'),
        destructiveHint: j.opt<bool>('destructiveHint'),
        idempotentHint: j.opt<bool>('idempotentHint'),
        openWorldHint: j.opt<bool>('openWorldHint'),
      );

  final String? title;
  final bool? readOnlyHint;
  final bool? destructiveHint;
  final bool? idempotentHint;
  final bool? openWorldHint;

  /// Spec defaults: readOnly=false, destructive=true (when not read-only),
  /// idempotent=false, openWorld=true.
  bool get isReadOnly => readOnlyHint ?? false;
  bool get isDestructive => !isReadOnly && (destructiveHint ?? true);
  bool get isIdempotent => isReadOnly || (idempotentHint ?? false);
  bool get isOpenWorld => openWorldHint ?? true;

  JsonMap toJson() => compact({
        'title': title,
        'readOnlyHint': readOnlyHint,
        'destructiveHint': destructiveHint,
        'idempotentHint': idempotentHint,
        'openWorldHint': openWorldHint,
      });

  /// What the approval policy assumes for a tool whose server is not
  /// trusted: the MCP worst case (not read-only, destructive, not
  /// idempotent, open-world). [title] is kept for display.
  ToolAnnotations get untrustedDefaults => ToolAnnotations(
        title: title,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      );
}

/// Where a tool comes from; drives namespacing, trust and the privacy view.
enum ToolSourceKind { builtin, mcp, onDevice }

@immutable
final class ToolSource {
  const ToolSource(this.kind, {this.serverId, this.serverName});

  factory ToolSource.fromJson(JsonMap j) => ToolSource(
        ToolSourceKind.values.byName(j.req<String>('kind')),
        serverId: j.opt<String>('serverId'),
        serverName: j.opt<String>('serverName'),
      );

  static const builtin = ToolSource(ToolSourceKind.builtin);

  final ToolSourceKind kind;
  final String? serverId;
  final String? serverName;

  JsonMap toJson() =>
      compact({'kind': kind.name, 'serverId': serverId, 'serverName': serverName});
}

/// A tool as offered to the model. [name] is the namespaced, model-facing
/// name (e.g. `github__create_issue`); [originalName] is what the server
/// expects on the wire.
@immutable
final class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.originalName,
    this.title,
    this.outputSchema,
    this.annotations = const ToolAnnotations(),
    this.source = ToolSource.builtin,
    this.uiResourceUri,
    this.modelVisible = true,
    this.requiresConfirmation = false,
    this.definitionHash,
  });

  factory ToolDefinition.fromJson(JsonMap j) => ToolDefinition(
        name: j.req<String>('name'),
        originalName: j.opt<String>('originalName'),
        title: j.opt<String>('title'),
        description: j.opt<String>('description') ?? '',
        inputSchema: j.optObj('inputSchema') ?? const {'type': 'object'},
        outputSchema: j.optObj('outputSchema'),
        annotations: ToolAnnotations.fromJson(j.optObj('annotations') ?? const {}),
        source: ToolSource.fromJson(j.optObj('source') ?? const {'kind': 'builtin'}),
        uiResourceUri: j.opt<String>('uiResourceUri'),
        modelVisible: j.opt<bool>('modelVisible') ?? true,
        requiresConfirmation: j.opt<bool>('requiresConfirmation') ?? false,
        definitionHash: j.opt<String>('definitionHash'),
      );

  final String name;
  final String? originalName;
  final String? title;
  final String description;
  final JsonMap inputSchema;
  final JsonMap? outputSchema;
  final ToolAnnotations annotations;
  final ToolSource source;

  /// MCP Apps: `ui://` resource rendered for this tool's results.
  final String? uiResourceUri;

  /// False for app-only tools (MCP Apps visibility ["app"]): callable by the
  /// view but never offered to the model.
  final bool modelVisible;

  /// Hygiene verdict of the router (e.g. a description that trips the
  /// injection scanner): every call needs the user's confirmation unless
  /// they granted this exact definition ([definitionHash]).
  final bool requiresConfirmation;

  /// Fingerprint of the definition as the user reviewed it (name,
  /// description, schemas, annotations). Grants are bound to it, so a
  /// changed definition no longer matches an earlier "allow" (R11 §9.7:
  /// "always" is per server + tool + hash).
  final String? definitionHash;

  String get wireName => originalName ?? name;
  String get displayName => title ?? annotations.title ?? name;

  ToolDefinition copyWith({
    String? name,
    String? description,
    JsonMap? inputSchema,
  }) =>
      ToolDefinition(
        name: name ?? this.name,
        originalName: originalName,
        title: title,
        description: description ?? this.description,
        inputSchema: inputSchema ?? this.inputSchema,
        outputSchema: outputSchema,
        annotations: annotations,
        source: source,
        uiResourceUri: uiResourceUri,
        modelVisible: modelVisible,
        requiresConfirmation: requiresConfirmation,
        definitionHash: definitionHash,
      );

  JsonMap toJson() => compact({
        'name': name,
        'originalName': originalName,
        'title': title,
        'description': description,
        'inputSchema': inputSchema,
        'outputSchema': outputSchema,
        'annotations': annotations.toJson(),
        'source': source.toJson(),
        'uiResourceUri': uiResourceUri,
        'modelVisible': modelVisible ? null : false,
        'requiresConfirmation': requiresConfirmation ? true : null,
        'definitionHash': definitionHash,
      });
}

/// A tool invocation requested by the model.
///
/// [rawArguments] keeps the exact text the model produced so parse-and-repair
/// decisions are auditable; [argumentsError] is set when even repair failed
/// (the loop then returns the error to the model instead of executing).
@immutable
final class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.rawArguments,
    this.argumentsError,
    this.repaired = false,
  });

  factory ToolCall.fromJson(JsonMap j) => ToolCall(
        id: j.req<String>('id'),
        name: j.req<String>('name'),
        arguments: j.optObj('arguments') ?? const {},
        rawArguments: j.opt<String>('rawArguments'),
        argumentsError: j.opt<String>('argumentsError'),
        repaired: j.opt<bool>('repaired') ?? false,
      );

  final String id;
  final String name;
  final JsonMap arguments;
  final String? rawArguments;
  final String? argumentsError;
  final bool repaired;

  bool get isValid => argumentsError == null;

  JsonMap toJson() => compact({
        'id': id,
        'name': name,
        'arguments': arguments,
        'rawArguments': rawArguments,
        'argumentsError': argumentsError,
        'repaired': repaired ? true : null,
      });
}

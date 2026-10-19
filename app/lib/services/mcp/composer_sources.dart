import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'mcp_runtime.dart';

/// A slash command backed by an MCP prompt (`prompts/list`).
@immutable
final class McpPromptCommand {
  const McpPromptCommand({required this.serverId, required this.serverName, required this.prompt, required this.trusted});

  final String serverId;
  final String serverName;
  final McpPrompt prompt;

  /// The server is trusted (built in, or by the user): its prompt text is
  /// not flagged as untrusted when it enters the conversation.
  final bool trusted;

  /// What the user types after `/`: `<server>:<prompt>`, lower-case.
  String get command => '${McpToolNamer.namespace(serverId)}:${prompt.name}'.toLowerCase();

  /// Untrusted display text.
  String get label => prompt.title ?? prompt.name;

  String? get description => prompt.description;

  List<McpPromptArgument> get arguments => prompt.arguments;

  /// Required arguments [values] does not fill.
  List<String> missing(Map<String, String> values) => [
        for (final a in arguments)
          if (a.required && (values[a.name]?.trim().isEmpty ?? true)) a.name,
      ];

  /// Parses what follows the command in the composer:
  /// `key=value` / `key="two words"` pairs; with no `=`, the text fills the
  /// arguments in order (all of it goes to the last one, so a one-argument
  /// prompt takes the whole rest as-is).
  Map<String, String> parseArguments(String rest) {
    final text = rest.trim();
    if (text.isEmpty || arguments.isEmpty) return const {};
    final names = {for (final a in arguments) a.name};
    final pairs = RegExp(r'''([A-Za-z_][\w-]*)=("([^"]*)"|'([^']*)'|(\S+))''').allMatches(text).toList();
    if (pairs.isNotEmpty && pairs.every((m) => names.contains(m.group(1)))) {
      return {for (final m in pairs) m.group(1)!: m.group(3) ?? m.group(4) ?? m.group(5)!};
    }
    if (arguments.length == 1) return {arguments.single.name: text};
    final words = text.split(RegExp(r'\s+'));
    final out = <String, String>{};
    for (var i = 0; i < arguments.length && i < words.length; i++) {
      out[arguments[i].name] = i == arguments.length - 1 ? words.sublist(i).join(' ') : words[i];
    }
    return out;
  }
}

/// One message a prompt expanded to.
@immutable
final class McpExpandedMessage {
  const McpExpandedMessage({required this.role, required this.content, this.metadata = const {}});

  final Role role;
  final List<ContentPart> content;

  /// `mcpPrompt` (server and prompt name) and, for an untrusted server,
  /// `UntrustedData.messageMetadataKey: true` so the agent loop counts the
  /// text as untrusted content (R11 §9.7).
  final JsonMap metadata;

  Message toMessage({required String id, String? parentId, required DateTime createdAt}) =>
      Message(id: id, parentId: parentId, role: role, content: content, createdAt: createdAt, metadata: metadata);
}

/// What `prompts/get` returned, ready for the composer.
@immutable
final class McpExpandedPrompt {
  const McpExpandedPrompt({required this.command, required this.messages, this.description});

  final McpPromptCommand command;
  final String? description;
  final List<McpExpandedMessage> messages;

  /// The text of the prompt's user messages (to put in the composer).
  String get userText => [
        for (final m in messages)
          if (m.role == Role.user)
            for (final p in m.content)
              if (p is TextPart) p.text,
      ].join('\n\n');
}

final class McpPromptArgumentsException implements Exception {
  const McpPromptArgumentsException(this.missing);

  final List<String> missing;

  String get message => 'Fill in ${missing.join(', ')} first.';

  @override
  String toString() => 'McpPromptArgumentsException($missing)';
}

/// An `@` mention of an MCP resource.
@immutable
final class McpResourceSuggestion {
  const McpResourceSuggestion({required this.serverId, required this.serverName, required this.resource});

  final String serverId;
  final String serverName;
  final McpResource resource;

  /// What the composer inserts after `@`: `<server>:<name>`.
  String get mention => '${McpToolNamer.namespace(serverId)}:${resource.name.isEmpty ? resource.uri : resource.name}';

  String get label => resource.title ?? (resource.name.isEmpty ? resource.uri : resource.name);
}

/// The data behind the composer's MCP slash commands and `@` mentions.
final class McpComposerSources {
  McpComposerSources(this.runtime, {this.perServerTimeout = const Duration(seconds: 4)});

  final McpRuntime runtime;
  final Duration perServerTimeout;

  /// Text resources up to this size are embedded; larger or binary ones
  /// are attached as links.
  static const int maxEmbeddedChars = 32 * 1024;

  Iterable<McpServerConfig> _servers(String? sessionId) => runtime.servers.where((c) =>
      c.enabled && (sessionId == null || runtime.enablement.isServerEnabled(sessionId, c.id)));

  bool _trusted(McpServerConfig c) => c.trusted || runtime.isBuiltIn(c.id);

  /// Prompts of every server enabled for [sessionId], as slash commands.
  /// Servers that are slow or down are skipped.
  Future<List<McpPromptCommand>> promptCommands({String? sessionId}) async {
    final lists = await Future.wait([
      for (final c in _servers(sessionId))
        runtime.promptsOf(c.id).timeout(perServerTimeout).then(
              (prompts) => [for (final p in prompts) McpPromptCommand(serverId: c.id, serverName: c.name, prompt: p, trusted: _trusted(c))],
              onError: (Object _) => <McpPromptCommand>[],
            ),
    ]);
    final out = [for (final l in lists) ...l]..sort((a, b) => a.command.compareTo(b.command));
    return out;
  }

  /// Runs `prompts/get` for [command] with [arguments]. Throws
  /// [McpPromptArgumentsException] when a required argument is missing.
  Future<McpExpandedPrompt> expand(McpPromptCommand command, Map<String, String> arguments, {CancellationToken? cancel}) async {
    final missing = command.missing(arguments);
    if (missing.isNotEmpty) throw McpPromptArgumentsException(missing);
    final c = await runtime.manager.connection(command.serverId);
    final r = await c.getPrompt(
      command.prompt.name,
      arguments: {for (final e in arguments.entries) if (e.value.trim().isNotEmpty) e.key: e.value},
      cancel: cancel,
      timeout: const Duration(seconds: 30),
    );
    return McpExpandedPrompt(
      command: command,
      description: r.description,
      messages: [
        for (final m in r.messages)
          McpExpandedMessage(
            role: m.role == 'assistant' ? Role.assistant : Role.user,
            content: [m.content.toContentPart()],
            metadata: {
              'mcpPrompt': {'serverId': command.serverId, 'name': command.prompt.name},
              if (!command.trusted) UntrustedData.messageMetadataKey: true,
            },
          ),
      ],
    );
  }

  /// Resources of servers enabled for [sessionId] whose name, title or URI
  /// contains [query] (case-insensitive), at most [limit].
  Future<List<McpResourceSuggestion>> resourceSuggestions(String query, {String? sessionId, int limit = 20}) async {
    final q = query.trim().toLowerCase();
    final lists = await Future.wait([
      for (final c in _servers(sessionId))
        runtime.resourcesOf(c.id).timeout(perServerTimeout).then(
              (rs) => [for (final r in rs) McpResourceSuggestion(serverId: c.id, serverName: c.name, resource: r)],
              onError: (Object _) => <McpResourceSuggestion>[],
            ),
    ]);
    bool matches(McpResourceSuggestion s) =>
        q.isEmpty ||
        s.resource.name.toLowerCase().contains(q) ||
        (s.resource.title?.toLowerCase().contains(q) ?? false) ||
        s.resource.uri.toLowerCase().contains(q) ||
        s.mention.contains(q);
    return [for (final l in lists) ...l.where(matches)].take(limit).toList();
  }

  /// The message part for a mention: the resource's text embedded when it
  /// is small text and [embed] is set (read now, `resources/read`), else a
  /// [ResourceLinkPart]. Either way the agent loop treats it as untrusted
  /// content.
  Future<ContentPart> resolveMention(McpResourceSuggestion s, {bool embed = true, CancellationToken? cancel}) async {
    final r = s.resource;
    ContentPart link() => ResourceLinkPart(
          uri: r.uri,
          name: r.name.isEmpty ? null : r.name,
          title: r.title,
          description: r.description,
          mimeType: r.mimeType,
          size: r.size,
        );
    final textual = r.mimeType == null || r.mimeType!.startsWith('text/') || r.mimeType!.contains('json') || r.mimeType!.contains('xml');
    if (!embed || !textual || (r.size != null && r.size! > maxEmbeddedChars)) return link();
    try {
      final c = await runtime.manager.connection(s.serverId);
      final read = await c.readResource(r.uri, cancel: cancel, timeout: const Duration(seconds: 20));
      final text = read.contents.whereType<McpTextResourceContents>().firstOrNull;
      if (text == null || text.text.length > maxEmbeddedChars) return link();
      return EmbeddedResourcePart(uri: text.uri, mimeType: text.mimeType ?? r.mimeType, text: text.text);
    } on CancelledException {
      rethrow;
    } on Object {
      return link();
    }
  }

  /// A short preview of a mention for the composer chip (no I/O).
  static String preview(McpResourceSuggestion s) {
    final d = s.resource.description;
    final t = d == null ? s.resource.uri : '$d · ${s.resource.uri}';
    return t.length > 120 ? '${t.substring(0, 119)}…' : t;
  }

  /// JSON-safe description of a mention (debugging, tests).
  static String describe(ContentPart p) => jsonEncode(p.toJson());
}

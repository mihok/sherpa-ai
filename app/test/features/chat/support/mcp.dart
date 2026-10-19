import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/mcp/composer_sources.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpPrompt, McpPromptArgument, McpResource;

McpPromptCommand promptCommand({bool trusted = false, List<McpPromptArgument> arguments = const []}) => McpPromptCommand(
      serverId: 'srv',
      serverName: 'Example tools',
      trusted: trusted,
      prompt: McpPrompt(name: 'review', raw: const {}, title: 'Review', description: 'Reviews a text', arguments: arguments),
    );

/// What `McpComposerSources.expand` returns for [command].
McpExpandedPrompt expandedPrompt(McpPromptCommand command, List<(Role, String)> messages) => McpExpandedPrompt(
      command: command,
      messages: [
        for (final (role, text) in messages)
          McpExpandedMessage(
            role: role,
            content: [TextPart(text)],
            metadata: {
              'mcpPrompt': {'serverId': command.serverId, 'name': command.prompt.name},
              if (!command.trusted) UntrustedData.messageMetadataKey: true,
            },
          ),
      ],
    );

McpResourceSuggestion resource(String name, {String uri = 'notes://today.md'}) => McpResourceSuggestion(
      serverId: 'srv',
      serverName: 'Example tools',
      resource: McpResource(uri: uri, name: name, raw: const {}, mimeType: 'text/markdown'),
    );

/// The MCP side of the composer, answered from maps.
final class FakeMcpSources implements ChatMcpSources {
  FakeMcpSources({this.prompts = const {}, this.parts = const {}});

  final Map<String, McpExpandedPrompt Function(Map<String, String> args)> prompts;
  final Map<String, ContentPart> parts;
  final List<(String, Map<String, String>)> expanded = [];
  final List<String> resolved = [];

  @override
  Future<McpExpandedPrompt> expand(McpPromptCommand command, Map<String, String> arguments) async {
    final missing = command.missing(arguments);
    if (missing.isNotEmpty) throw McpPromptArgumentsException(missing);
    expanded.add((command.command, arguments));
    return prompts[command.command]!(arguments);
  }

  @override
  Future<ContentPart> resolveMention(McpResourceSuggestion mention) async {
    resolved.add(mention.mention);
    return parts[mention.resource.name] ?? ResourceLinkPart(uri: mention.resource.uri, name: mention.resource.name);
  }
}

const ProviderInfo kLocalInfo = ProviderInfo(
  id: localProviderId,
  kind: ProviderKind.localLlamaCpp,
  displayName: kLocalProviderName,
  location: ExecutionLocation.onDevice,
);


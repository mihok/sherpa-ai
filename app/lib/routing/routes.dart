/// Every path in the app. Use these instead of string literals so a rename is
/// one edit and deep links stay in sync with the router table.
abstract final class Routes {
  static const onboarding = '/onboarding';
  static const home = '/';
  static const settings = '/settings';
  static const providers = '/settings/providers';
  static const newProvider = '/settings/providers/new';
  static const privacy = '/settings/privacy';
  static const about = '/settings/about';

  /// On-device models: the local library (root), the Hub browser and the
  /// download queue.
  static const models = '/settings/models';
  static const modelBrowse = '/settings/models/browse';
  static const downloads = '/settings/models/downloads';
  static const huggingFace = '/settings/huggingface';

  /// The performance lab of one on-device model (library id).
  static String modelPerformance(String modelId) => '$models/performance/${Uri.encodeComponent(modelId)}';

  /// MCP tool servers: the list, add (by URL, QR, registry or deep link),
  /// the registry search, remembered approvals, one server, its console and
  /// a tool's review.
  static const tools = '/settings/tools';
  static const addServer = '/settings/tools/add';
  static const toolRegistry = '/settings/tools/registry';
  static const toolApprovals = '/settings/tools/approvals';

  static String toolServer(String serverId) => '$tools/servers/${Uri.encodeComponent(serverId)}';

  static String toolServerConsole(String serverId) => '${toolServer(serverId)}/console';

  static String toolReview(String serverId, String toolName) =>
      '${toolServer(serverId)}/review/${Uri.encodeComponent(toolName)}';

  /// The add screen filled in (`source`: url, registry, link or qr).
  static String addServerWith({required String url, String? name, String? source, String? registryName, String? description}) =>
      Uri(path: addServer, queryParameters: {
        'url': url,
        'name': ?name,
        'source': ?source,
        'registry': ?registryName,
        'description': ?description,
      }).toString();

  /// A Hub repo's detail page (`owner/name` as two path segments).
  static String modelDetail(String repoId) {
    final i = repoId.indexOf('/');
    final owner = i < 0 ? repoId : repoId.substring(0, i);
    final name = i < 0 ? '' : repoId.substring(i + 1);
    return '$modelBrowse/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(name)}';
  }

  static String chat(String sessionId) => '/chat/${Uri.encodeComponent(sessionId)}';

  /// What the model sees for a chat: budget, items, overlays, undo (M3).
  static String chatContext(String sessionId) => '${chat(sessionId)}/context';

  /// Review a handoff bundle of a chat, then continue it elsewhere (M3).
  static String chatHandoff(String sessionId) => '${chat(sessionId)}/handoff';

  /// Continue a task from a handoff file, pasted text or a QR code.
  static const handoffImport = '/handoff/import';

  static String provider(String providerId) => '/settings/providers/${Uri.encodeComponent(providerId)}';

  /// New-provider form preselected with a preset id from `ProviderPresets`.
  static String newProviderWithPreset(String presetId) => '$newProvider?preset=${Uri.encodeQueryComponent(presetId)}';

  /// Session id when [path] is a chat route or one of its sub-routes
  /// (`/chat/:id/context`, `/chat/:id/handoff`), else null. The tablet
  /// sessions list keeps the chat selected on those pages too.
  static String? chatIdOf(String path) {
    final segments = Uri.parse(path).pathSegments;
    if (segments.length < 2 || segments.first != 'chat' || segments[1].isEmpty) return null;
    if (segments.length == 2) return segments[1];
    return segments.length == 3 && _chatSubRoutes.contains(segments[2]) ? segments[1] : null;
  }

  static const _chatSubRoutes = {'context', 'handoff'};

  static bool isSettings(String path) => path == settings || path.startsWith('$settings/');
}

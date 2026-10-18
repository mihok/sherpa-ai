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

  static String chat(String sessionId) => '/chat/${Uri.encodeComponent(sessionId)}';

  static String provider(String providerId) => '/settings/providers/${Uri.encodeComponent(providerId)}';

  /// New-provider form preselected with a preset id from `ProviderPresets`.
  static String newProviderWithPreset(String presetId) => '$newProvider?preset=${Uri.encodeQueryComponent(presetId)}';

  /// Session id when [path] is a chat route, else null.
  static String? chatIdOf(String path) {
    final segments = Uri.parse(path).pathSegments;
    return segments.length == 2 && segments.first == 'chat' ? segments[1] : null;
  }

  static bool isSettings(String path) => path == settings || path.startsWith('$settings/');
}

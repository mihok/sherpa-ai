import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../design/widgets/state_views.dart';
import '../features/home/home_screen.dart';
import '../features/models/downloads_screen.dart';
import '../features/models/hf_account_screen.dart';
import '../features/models/model_detail_screen.dart';
import '../features/models/model_directory_screen.dart';
import '../features/models/model_library_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/privacy_screen.dart';
import '../features/settings/provider_form_screen.dart';
import '../features/settings/providers_screen.dart';
import '../features/settings/settings_screen.dart';
import '../shell/app_shell.dart';
import '../state/providers.dart';
import 'chat_route.dart';
import 'routes.dart';
import 'sherpa_page.dart';

/// Route table:
///
/// ```
/// /onboarding                    first-run flow (outside the shell)
/// /                              home: sessions list (phone) / placeholder (tablet)
/// /chat/:id                      a chat (detail pane on tablets)
/// /settings                      settings root
/// /settings/providers            configured providers
/// /settings/providers/new        add a provider (?preset=openai|anthropic|…)
/// /settings/providers/:id        edit a provider
/// /settings/privacy              privacy dashboard
/// /settings/about                versions and licenses
/// /settings/models               on-device models (library, disk usage, import)
/// /settings/models/browse        Hugging Face browser
/// /settings/models/browse/:owner/:name   a repo: variants, fit, download
/// /settings/models/downloads     download queue
/// /settings/huggingface          Hugging Face token
/// ```
///
/// Everything but onboarding is nested under `/`, so the back stack is
/// always meaningful (system back from a chat or settings returns home
/// instead of leaving the app), and predictive back can preview it.
final routerProvider = Provider<GoRouter>((ref) {
  final prefs = ref.watch(preferencesProvider);
  final router = GoRouter(
    initialLocation: Routes.home,
    restorationScopeId: 'router',
    // Only ever redirect *into* onboarding. Leaving it is an explicit
    // navigation, so "Run setup again" from settings works.
    redirect: (context, state) =>
        !prefs.onboardingComplete && state.matchedLocation != Routes.onboarding ? Routes.onboarding : null,
    errorPageBuilder: (context, state) => SherpaPage<void>(key: state.pageKey, child: const NotFoundScreen()),
    routes: [
      GoRoute(
        path: Routes.onboarding,
        pageBuilder: (context, state) =>
            SherpaPage<void>(key: state.pageKey, restorationId: 'onboarding', child: const OnboardingScreen()),
      ),
      ShellRoute(
        restorationScopeId: 'shell',
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: Routes.home,
            pageBuilder: (context, state) =>
                SherpaPage<void>(key: state.pageKey, restorationId: 'home', child: const HomeScreen()),
            routes: [
              GoRoute(
                path: 'chat/:id',
                pageBuilder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return SherpaPage<void>(
                    key: state.pageKey,
                    role: PaneRole.detail,
                    restorationId: 'chat',
                    child: ChatRouteView(sessionId: id),
                  );
                },
              ),
              GoRoute(
                path: 'settings',
                pageBuilder: (context, state) => SherpaPage<void>(
                  key: state.pageKey,
                  role: PaneRole.destination,
                  restorationId: 'settings',
                  child: const SettingsScreen(),
                ),
                routes: [
                  GoRoute(
                    path: 'providers',
                    pageBuilder: (context, state) =>
                        SherpaPage<void>(key: state.pageKey, restorationId: 'providers', child: const ProvidersScreen()),
                    routes: [
                      // 'new' before ':id' so it isn't captured as an id.
                      GoRoute(
                        path: 'new',
                        pageBuilder: (context, state) => SherpaPage<void>(
                          key: state.pageKey,
                          child: ProviderFormScreen(presetId: state.uri.queryParameters['preset']),
                        ),
                      ),
                      GoRoute(
                        path: ':id',
                        pageBuilder: (context, state) => SherpaPage<void>(
                          key: state.pageKey,
                          child: ProviderFormScreen(providerId: state.pathParameters['id']),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'privacy',
                    pageBuilder: (context, state) =>
                        SherpaPage<void>(key: state.pageKey, restorationId: 'privacy', child: const PrivacyScreen()),
                  ),
                  GoRoute(
                    path: 'about',
                    pageBuilder: (context, state) =>
                        SherpaPage<void>(key: state.pageKey, restorationId: 'about', child: const AboutScreen()),
                  ),
                  GoRoute(
                    path: 'models',
                    pageBuilder: (context, state) =>
                        SherpaPage<void>(key: state.pageKey, restorationId: 'models', child: const ModelLibraryScreen()),
                    routes: [
                      GoRoute(
                        path: 'browse',
                        pageBuilder: (context, state) => SherpaPage<void>(
                          key: state.pageKey,
                          restorationId: 'model-browse',
                          child: const ModelDirectoryScreen(),
                        ),
                        routes: [
                          GoRoute(
                            path: ':owner/:name',
                            pageBuilder: (context, state) => SherpaPage<void>(
                              key: state.pageKey,
                              child: ModelDetailScreen(
                                repoId: '${state.pathParameters['owner']}/${state.pathParameters['name']}',
                              ),
                            ),
                          ),
                        ],
                      ),
                      GoRoute(
                        path: 'downloads',
                        pageBuilder: (context, state) =>
                            SherpaPage<void>(key: state.pageKey, restorationId: 'downloads', child: const DownloadsScreen()),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'huggingface',
                    pageBuilder: (context, state) =>
                        SherpaPage<void>(key: state.pageKey, child: const HuggingFaceAccountScreen()),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// The chat route's content, resolved through [chatScreenBuilderProvider].
class ChatRouteView extends ConsumerWidget {
  const ChatRouteView({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      KeyedSubtree(key: ValueKey('chat:$sessionId'), child: ref.watch(chatScreenBuilderProvider)(sessionId));
}

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: StateView(
          title: "This page doesn't exist",
          message: 'The link may be out of date.',
          icon: Icons.explore_off_outlined,
          primaryAction: FilledButton(onPressed: () => context.go(Routes.home), child: const Text('Go to chats')),
        ),
      );
}

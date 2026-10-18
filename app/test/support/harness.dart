import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/design/haptics.dart';
import 'package:sherpa/routing/chat_route.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/state/connectivity.dart';
import 'package:sherpa/state/in_memory/in_memory_preferences_store.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// What a fake endpoint does when probed.
final class FakeEndpoint {
  const FakeEndpoint({this.models = const [], this.error});

  final List<String> models;
  final ProviderException? error;
}

/// Model provider whose `listModels` answers from a [FakeEndpoint].
final class FakeModelProvider implements ModelProvider {
  FakeModelProvider(this.config, this.endpoint, this.apiKey);

  final ProviderConfig config;
  final FakeEndpoint endpoint;
  final String? apiKey;

  @override
  ProviderInfo get info => ProviderInfo(
        id: config.id,
        kind: ProviderKind.fake,
        displayName: config.displayName,
        location: ExecutionLocation.remote,
        baseUrl: config.baseUrl,
      );

  @override
  Future<List<ModelDescriptor>> listModels() async {
    final e = endpoint.error;
    if (e != null) throw e;
    return [
      for (final m in endpoint.models)
        ModelDescriptor(id: m, providerId: config.id, displayName: m, capabilities: ModelCapabilities.unknown),
    ];
  }

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => ModelCapabilities.unknown;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) => const Stream.empty();
}

/// Records haptic calls instead of vibrating.
final class RecordingHaptics implements HapticsDriver {
  final List<HapticKind> calls = [];

  @override
  Future<void> perform(HapticKind kind) async => calls.add(kind);
}

/// The app wired to in-memory services and fakes.
final class Harness {
  Harness({
    Iterable<ProviderConfig> providers = const [],
    Map<String, String> keys = const {},
    this.endpoints = const {},
    ModelChoice? defaultModel,
    bool onboarded = true,
    DateTime? now,
  })  : clock = FakeClock(now ?? DateTime.utc(2026, 10, 18, 12)),
        prefs = InMemoryPreferencesStore(defaultModel: defaultModel, onboardingComplete: onboarded) {
    for (final e in keys.entries) {
      unawaited(secrets.write(e.key, e.value));
    }
    registry = InMemoryProviderRegistry(
      secrets: secrets,
      initial: providers,
      factory: (config, apiKey) {
        apiKeysSeen[config.id] = apiKey;
        return FakeModelProvider(config, endpoints[config.baseUrl.host] ?? const FakeEndpoint(), apiKey);
      },
    );
  }

  /// Behaviour per base URL host.
  final Map<String, FakeEndpoint> endpoints;
  final FakeClock clock;
  final SequentialIdGenerator ids = SequentialIdGenerator();
  final InMemorySecretStore secrets = InMemorySecretStore();
  final ObservableSessionStore store = ObservableSessionStore(InMemorySessionStore());
  late final InMemoryProviderRegistry registry;
  final InMemoryPreferencesStore prefs;
  final InMemoryUiPreferencesStore ui = InMemoryUiPreferencesStore();
  final StreamController<List<ConnectivityResult>> connectivity = StreamController.broadcast();
  final RecordingHaptics haptics = RecordingHaptics();
  final Map<String, String?> apiKeysSeen = {};

  List<Override> get overrides => [
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(ids),
        secretStoreProvider.overrideWithValue(secrets),
        sessionStoreProvider.overrideWithValue(store),
        providerRegistryProvider.overrideWithValue(registry),
        preferencesProvider.overrideWithValue(prefs),
        uiPreferencesStoreProvider.overrideWithValue(ui),
        connectivityStreamProvider.overrideWithValue(connectivity.stream),
        hapticsDriverProvider.overrideWithValue(haptics),
        chatScreenBuilderProvider.overrideWithValue(FakeChatScreen.new),
      ];

  Widget app() => ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp());

  Future<SessionRecord> addSession(String title, {String? providerId, String? modelId, Duration age = Duration.zero}) {
    final at = clock.now().subtract(age);
    return store.putSession(SessionRecord(
      id: ids.next('seed'),
      title: title,
      createdAt: at,
      updatedAt: at,
      providerId: providerId,
      modelId: modelId,
    ));
  }
}

/// Stands in for the chat feature in shell tests.
class FakeChatScreen extends StatelessWidget {
  const FakeChatScreen(this.sessionId, {super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Chat $sessionId')),
        body: Center(child: Text('chat:$sessionId')),
      );
}

/// Answers platform channels the app touches that flutter_test leaves
/// unanswered. `SensitiveContent` (API key fields) hides its child until the
/// platform replies, so without this the key field would never appear.
void mockPlatformChannels(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.sensitiveContent,
    (call) async => switch (call.method) {
      'SensitiveContent.isSupported' => false,
      _ => null,
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.sensitiveContent, null),
  );
}

/// Sizes the test window in logical pixels.
void setWindow(WidgetTester tester, Size size, {double textScale = 1}) {
  mockPlatformChannels(tester);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> pumpApp(WidgetTester tester, Harness h, {Size size = const Size(400, 860), double textScale = 1}) async {
  setWindow(tester, size, textScale: textScale);
  await tester.pumpWidget(h.app());
  await tester.pumpAndSettle();
}

const phone = Size(400, 860);
const smallTablet = Size(720, 1000);
const tablet = Size(1200, 840);

ProviderConfig openAiConfig({String id = 'openai'}) => ProviderConfig(
      id: id,
      flavor: ApiFlavor.openAiResponses,
      displayName: 'OpenAI',
      baseUrl: Uri.parse('https://api.openai.com/v1'),
      profile: ServerProfile.openAi,
    );

ProviderConfig ollamaConfig({String id = 'ollama'}) => ProviderConfig(
      id: id,
      flavor: ApiFlavor.openAiChat,
      displayName: 'Ollama',
      baseUrl: Uri.parse('http://192.168.1.20:11434/v1'),
      profile: ServerProfile.ollama,
      allowLocalNetwork: true,
    );

/// Navigates the running app (as a deep link would).
Future<void> goTo(WidgetTester tester, String location) async {
  final container = ProviderScope.containerOf(tester.element(find.byType(SherpaApp)));
  container.read(routerProvider).go(location);
  await tester.pumpAndSettle();
}

Finder fieldLabeled(String label) =>
    find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

Future<void> tapText(WidgetTester tester, String text, {int index = 0}) async {
  final f = find.text(text);
  await tester.ensureVisible(f.at(index));
  await tester.pumpAndSettle();
  await tester.tap(f.at(index));
  await tester.pumpAndSettle();
}

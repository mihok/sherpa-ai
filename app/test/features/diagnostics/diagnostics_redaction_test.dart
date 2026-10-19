import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/diagnostics/diagnostics_collector.dart';
import 'package:sherpa/features/diagnostics/diagnostics_providers.dart';
import 'package:sherpa/features/diagnostics/diagnostics_scrubber.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/features/perf/state/perf_providers.dart';
import 'package:sherpa/services/downloads/downloads.dart' show ModelStorageLayout;
import 'package:sherpa/services/downloads/model_library.dart';
import 'package:sherpa/services/downloads/record_store.dart';
import 'package:sherpa/services/mcp/auth/mcp_oauth.dart' show McpAuthState;
import 'package:sherpa/services/mcp/mcp_records.dart' show McpServerMeta, McpServerSource;
import 'package:sherpa/state/in_memory/in_memory_preferences_store.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/provider_location.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, FileRole, ModelFormat;
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Redactor;
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// Every secret, piece of chat content, URL query and home path the app
/// holds is seeded in every place it can live; none of them may reach the
/// diagnostics bundle or its summary.
void main() {
  // Secrets in the secret store (API keys, the HF token, OAuth tokens).
  const openAiKey = 'sk-proj-SEEDopenaiKEY0123456789abcdef';
  const plainKey = 'plain-secret-SEED-noPattern-42'; // no known token shape
  const hfToken = 'hf_SEEDhuggingfaceTOKEN0123456789ab';
  const oauthAccess = 'oauthAccessSEED9876543210zyx';
  const oauthRefresh = 'oauthRefreshSEED1234567890abc';
  // User content: chat messages, prompts, tool arguments and results, titles.
  const chatText = 'CHATSEED my diagnosis is confidential';
  const systemPrompt = 'PROMPTSEED you are my therapist';
  const toolArgs = 'TOOLARGSSEED-street-address';
  const toolResult = 'TOOLRESULTSEED-bank-balance';
  const title = 'TITLESEED Nightingale';
  // Names the user typed, a header value, a query token, home paths.
  const providerName = 'NAMESEED Alice at work';
  const serverName = 'MCPNAMESEED private notes';
  const headerValue = 'HEADERSEED-org-value';
  const queryToken = 'QUERYTOKENSEED123';
  const querySig = 'SIGSEED999';
  const home = '/home/alice';
  const homeModel = '$home/models/private-model.gguf';
  const macModel = '/Users/alice/Library/models/other.gguf';
  const androidData = '/data/user/0/ai.sherpa.app/files/crash-notes.txt';
  const importedName = 'IMPORTSEED alice-diary-finetune';

  const seeds = [
    openAiKey,
    plainKey,
    hfToken,
    oauthAccess,
    oauthRefresh,
    chatText,
    'CHATSEED',
    systemPrompt,
    toolArgs,
    toolResult,
    title,
    providerName,
    serverName,
    headerValue,
    queryToken,
    querySig,
    home,
    'alice',
    androidData,
    importedName,
    'IMPORTSEED',
    'hunter2pass',
  ];

  late ProviderContainer container;
  late Directory tmp;

  setUp(() async {
    localHostVerdicts.clear();
    tmp = await Directory.systemTemp.createTemp('diag_test_');
    final secrets = InMemorySecretStore();
    await secrets.write('provider/openai/api_key', openAiKey);
    await secrets.write('provider/lan/api_key', plainKey);
    await secrets.write('hf/token', hfToken);
    await secrets.write('mcp/m1/access_token', oauthAccess);
    await secrets.write('mcp/m1/refresh_token', oauthRefresh);

    final registry = InMemoryProviderRegistry(
      secrets: secrets,
      factory: (config, key) => throw StateError('no network in tests'),
      initial: [
        ProviderConfig(
          id: 'openai',
          flavor: ApiFlavor.openAiResponses,
          displayName: providerName,
          baseUrl: Uri.parse('https://bob:hunter2pass@api.openai.com/v1?api-version=2024&sig=$querySig&token=$queryToken'),
          headers: const {'X-Org': headerValue},
          defaultModelId: 'gpt-5-mini',
        ),
        ProviderConfig(
          id: 'lan',
          flavor: ApiFlavor.openAiChat,
          displayName: 'LAN $providerName',
          baseUrl: Uri.parse('http://192.168.1.20:8080/v1'),
          profile: ServerProfile.llamaCpp,
          allowLocalNetwork: true,
          // llama.cpp servers report the GGUF path as the model id.
          defaultModelId: homeModel,
          modelOverrides: const {macModel: ModelCapabilities(contextLength: 8192)},
        ),
      ],
    );

    final store = ObservableSessionStore(InMemorySessionStore());
    final at = DateTime.utc(2026, 10, 19, 9);
    await store.putSession(SessionRecord(
      id: 's1',
      title: title,
      createdAt: at,
      updatedAt: at,
      providerId: 'openai',
      modelId: 'gpt-5-mini',
      systemPrompt: systemPrompt,
      activeLeafId: 'm3',
    ));
    await store.putMessage('s1', Message(id: 'm1', role: Role.user, content: const [TextPart(chatText)], createdAt: at));
    await store.putMessage(
      's1',
      Message(
        id: 'm2',
        parentId: 'm1',
        role: Role.assistant,
        createdAt: at,
        content: const [
          ToolCallPart(ToolCall(id: 'c1', name: 'notes__save', arguments: {'address': toolArgs, 'url': 'https://x.test/?token=$queryToken'})),
        ],
      ),
    );
    await store.putMessage(
      's1',
      Message(
        id: 'm3',
        parentId: 'm2',
        role: Role.tool,
        createdAt: at,
        content: const [
          ToolResultPart(callId: 'c1', toolName: 'notes__save', content: [TextPart('$toolResult at $homeModel')]),
        ],
      ),
    );

    final ring = AppErrorRing(now: () => at);
    ring
      ..record(const ProviderException(ProviderErrorKind.rateLimited, 'GET https://api.openai.com/v1?key=$openAiKey', statusCode: 429))
      ..record(const FormatException('Unexpected character in $chatText'), source: 'chat')
      ..record(const FileSystemException('Cannot open file', androidData))
      ..record(StateError('$homeModel is gone'));

    final records = InMemoryRecordStore();
    final mcpConfig = McpServerConfig(
      id: 'm1',
      name: serverName,
      url: Uri.parse('https://mcp.example.com:8443/sse?token=$queryToken&access_token=$oauthAccess'),
      headers: const {'X-Workspace': headerValue},
    );
    final view = McpServerView(
      config: mcpConfig,
      health: McpServerHealth(
        serverId: 'm1',
        status: McpServerStatus.error,
        lastError: 'McpTransportException: GET https://mcp.example.com/sse?access_token=$oauthAccess failed '
            '(HTTP 502) while reading $home/.cache/mcp.log: $chatText',
        lastErrorAt: at,
        era: McpEra.legacy,
        protocolVersion: '2025-06-18',
        serverName: serverName,
      ),
      builtIn: false,
      meta: McpServerMeta(source: McpServerSource.registry, registryName: 'io.github.alice/$serverName', description: serverName),
      tools: const [],
      auth: const McpAuthState(failure: 'Sign-in failed for alice@example.com with $oauthRefresh'),
      refreshError: null,
    );

    final device = DeviceSnapshot(
      platform: DevicePlatform.android,
      osVersion: '17',
      apiLevel: 37,
      manufacturer: 'Google',
      model: 'Pixel 9',
      socManufacturer: 'Google',
      socModel: 'Tensor G4',
      totalRamBytes: 12 * 1024 * 1024 * 1024,
      cpu: const CpuInfo(cores: 8, performanceCores: 4, features: {'dotprod', 'i8mm'}),
      thermal: ThermalLevel.fair,
      lowPowerMode: true,
      capturedAt: at,
      lastExit: ExitForensics(
        reason: 13,
        reasonName: 'REASON_OTHER',
        kind: ExitKind.memoryLimiter,
        timestamp: at,
        description: 'crashed reading $androidData: $chatText',
        processName: 'ai.sherpa.app:inference',
        processStateSummary: utf8.encode('v1 p=decode m=1a2b3c4d b=cpu c=8192 fg=1'),
      ),
    );

    container = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(FakeClock(at)),
      secretStoreProvider.overrideWithValue(secrets),
      providerRegistryProvider.overrideWithValue(registry),
      sessionStoreProvider.overrideWithValue(store),
      preferencesProvider.overrideWithValue(
        InMemoryPreferencesStore(defaultModel: const ModelChoice(providerId: 'lan', modelId: homeModel), onboardingComplete: true),
      ),
      chatAgentConfigProvider.overrideWithValue(const AgentConfig(defaultSystemPrompt: systemPrompt)),
      appErrorRingProvider.overrideWithValue(ring),
      mcpServersProvider.overrideWithValue([view]),
      perfDeviceReaderProvider.overrideWithValue(() async => device),
      modelRecordStoreProvider.overrideWithValue(records),
      modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout(tmp.path)),
      diagnosticsDatabaseSizeProvider.overrideWithValue(() async => 123456),
      diagnosticsPrivatePathsProvider.overrideWithValue(() async => ['/data/user/0/ai.sherpa.app/files']),
    ]);
    await container.read(modelLibraryProvider).add(LibraryModel(
          id: 'imported-$importedName',
          source: LibrarySource.imported,
          displayName: importedName,
          format: ModelFormat.gguf,
          files: const [LibraryFile(path: 'imported/$importedName.gguf', role: FileRole.model, sizeBytes: 1000)],
          loadPath: 'imported/$importedName.gguf',
          installedAt: at,
          quant: 'Q4_K_M',
        ));
    await container.read(modelLibraryProvider).add(LibraryModel(
          id: 'hub-qwen',
          source: LibrarySource.hub,
          displayName: 'Qwen3 0.6B',
          format: ModelFormat.gguf,
          files: const [LibraryFile(path: 'hub/qwen.gguf', role: FileRole.model, sizeBytes: 400000000)],
          loadPath: 'hub/qwen.gguf',
          installedAt: at,
          repo: 'unsloth/Qwen3-0.6B-GGUF',
          quant: 'Q8_0',
        ));
  });

  tearDown(() async {
    container.dispose();
    await tmp.delete(recursive: true);
  });

  Future<DiagnosticsBundle> collect() =>
      DiagnosticsCollector(container.read, environment: const {'HOME': home}).collect();

  test('no secret, chat content, URL query or home path reaches the bundle or the summary', () async {
    final b = await collect();
    final json = b.json;
    for (final seed in seeds) {
      expect(json.contains(seed), isFalse, reason: 'bundle leaks "$seed"');
      expect(b.summary.contains(seed), isFalse, reason: 'summary leaks "$seed"');
    }
    // No URL keeps a path or query; no path under a home or data directory.
    expect(RegExp(r'://[^\s"]*[/?#]').hasMatch(json), isFalse, reason: 'a URL kept more than its origin');
    expect(RegExp(r'/(home|Users|data/user)/').hasMatch(json), isFalse);
    expect(json.contains('?'), isFalse);
    expect(json.contains('@'), isFalse, reason: 'user info or an e-mail address survived');
  });

  test('the bundle still says what a bug report needs', () async {
    final b = await collect();
    final d = b.data;
    final device = d['device']! as Map;
    expect(device['displayModel'], 'Google Pixel 9');
    expect(device['socModel'], 'Tensor G4');
    expect(device['cpuClass'], isNotNull);
    expect(device['thermal'], 'fair');
    expect(device['batterySaver'], isTrue);
    expect((d['os']! as Map)['apiLevel'], 37);

    final exit = d['lastExit']! as Map;
    expect(exit['kind'], 'memoryLimiter');
    expect(exit['description'], '«omitted»', reason: 'free-text exit descriptions are dropped');
    expect((exit['processState']! as Map)['phase'], 'decode');
    expect((exit['processState']! as Map)['contextTokens'], 8192);

    final providers = (d['providers']! as List).cast<Map<Object?, Object?>>();
    expect(providers.map((p) => p['host']), ['api.openai.com', '192.168.1.20:8080']);
    expect(providers.map((p) => p['location']), ['remote', 'localNetwork']);
    expect(providers.map((p) => p['apiKeySet']), [true, true]);
    expect(providers.first['customHeaders'], 1);
    expect(providers.first['defaultModelId'], 'gpt-5-mini');
    expect(providers.first['modelsInChats'], {'gpt-5-mini': 1});
    expect(providers.last['defaultModelId'], DiagnosticsScrubber.pathMask);
    expect((d['defaultModel']! as Map)['provider'], 'p2');

    final server = (d['mcpServers']! as List).single as Map;
    expect(server['host'], 'mcp.example.com:8443');
    expect(server['era'], 'legacy');
    expect(server['status'], 'error');
    expect(server['lastErrorType'], 'McpTransportException');
    expect(server['lastErrorCode'], 'http_502');
    expect(server['toolCount'], 0);
    expect(server['signInFailed'], isTrue);

    final data = d['data']! as Map;
    expect(data['chats'], 1);
    expect(data['messages'], 3);
    expect(data['databaseBytes'], 123456);
    expect(data['storage'], 'memory');

    final errors = ((d['errors']! as Map)['recent']! as List).cast<Map<Object?, Object?>>();
    expect(errors.map((e) => e['type']), ['ProviderException', 'FormatException', 'FileSystemException', 'StateError']);
    expect(errors.first['code'], 'rateLimited_429');
    expect(errors[1]['source'], 'chat');

    final models = (d['localModels']! as List).cast<Map<Object?, Object?>>();
    final imported = models.firstWhere((m) => m['source'] == 'imported');
    expect(imported['id'], ProcessStateSummary.hashModelId('imported-$importedName'));
    expect(imported['repo'], isNull);
    expect(models.firstWhere((m) => m['source'] == 'hub')['repo'], 'unsloth/Qwen3-0.6B-GGUF');

    expect((d['engine']! as Map)['wired'], isFalse);
    expect((d['perfLab']! as Map)['available'], isFalse);
    expect(((d['context']! as Map)['settings']! as Map)['autoCompact'], isTrue);

    expect(b.summary, contains('Google Pixel 9'));
    expect(b.summary, contains('api.openai.com'));
    expect(b.summary, contains('key set'));
    expect(b.summary, contains('1 chat (0 archived)'));
    expect(b.summary, contains('3 messages'));
    expect(b.fileName, startsWith('sherpa-diagnostics-2026-10-'));
    expect(jsonDecode(utf8.decode(b.bytes)), b.data);
  });

  test('an unwired part of the app is reported as unavailable, not a failure', () async {
    final bare = ProviderContainer(overrides: [
      perfDeviceReaderProvider.overrideWithValue(() async => null),
      diagnosticsPrivatePathsProvider.overrideWithValue(() async => const []),
    ]);
    addTearDown(bare.dispose);
    final b = await DiagnosticsCollector(bare.read, environment: const {}).collect();
    expect((b.data['providers']! as Map)['unavailable'], isNotNull);
    expect((b.data['mcpServers']! as Map)['unavailable'], isNotNull);
    expect((b.data['device']! as Map)['unavailable'], isNotNull);
    expect(b.data['app'], isA<Map<Object?, Object?>>());
    expect(b.summary, contains('Model providers: unavailable'));
  });

  test("the engine's system info keeps listed fields only, and its strings are scrubbed", () {
    final info = DiagnosticsCollector.engineSystemInfo(jsonEncode({
      'engine': 'sherpa-engine 0.3.1',
      'abi_version': 3,
      'backend_init': 'loaded $home/app/lib/libggml-cpu.so',
      'cpu_variant': 'android_armv8.6_1',
      'backends': [
        {'name': 'CPU', 'n_devices': 1, 'path': '$home/x'},
      ],
      'devices': [
        {'name': 'CPU', 'description': 'ARMv8 at $home/proc', 'type': 'cpu', 'memory_total': 1, 'serial': 'SERIALSEED'},
      ],
      'cpu': {
        'arch': 'arm64',
        'logical_cores': 8,
        'features': {'dotprod': true, 'i8mm': true},
        'note': 'NOTESEED',
      },
      'future_field': 'FUTURESEED',
    }));
    final scrubbed = jsonEncode(DiagnosticsScrubber(homePaths: const [home]).tree(info));
    expect(info.containsKey('backend_init'), isFalse);
    expect(info.containsKey('future_field'), isFalse);
    expect(scrubbed, isNot(contains('SERIALSEED')));
    expect(scrubbed, isNot(contains('NOTESEED')));
    expect(scrubbed, isNot(contains(home)));
    expect(scrubbed, contains('android_armv8.6_1'));
    expect((info['cpu']! as Map)['features'], {'dotprod': true, 'i8mm': true});
  });

  group('DiagnosticsScrubber', () {
    final s = DiagnosticsScrubber(knownSecrets: const [plainKey, 'short'], homePaths: const [home]);

    test('cuts URLs to their origin and masks paths, e-mails and known secrets', () {
      expect(s.text('see https://u:p@host.test:8443/a/b?token=x#f now'), 'see https://host.test:8443 now');
      expect(s.text('file:///home/alice/x'), Redactor.mask);
      expect(s.text('at $homeModel and C:\\Users\\alice\\x.txt'), 'at ${DiagnosticsScrubber.pathMask} and ${DiagnosticsScrubber.pathMask}');
      expect(s.text('/var/mobile/Containers/Data/Application/ABC/Library'), DiagnosticsScrubber.pathMask);
      expect(s.text('mail alice@example.com'), 'mail ${DiagnosticsScrubber.emailMask}');
      expect(s.text('key $plainKey!'), 'key ${Redactor.mask}!');
      expect(s.text('Bearer abcdefghijklmnop'), 'Bearer ${Redactor.mask}');
      expect(s.text('short words stay'), 'short words stay', reason: 'values under 8 characters are not masked by value');
      expect(s.text('api.openai.com'), 'api.openai.com');
    });

    test('reports leaks of known secrets', () {
      expect(s.leaks('x $plainKey y'), [plainKey]);
      expect(s.leaks('clean'), isEmpty);
    });
  });

  group('AppErrorRing', () {
    test('keeps the newest records up to its capacity and counts the dropped ones', () {
      final ring = AppErrorRing(capacity: 3);
      for (var i = 0; i < 5; i++) {
        ring.record(StateError('$i'));
      }
      expect(ring.records, hasLength(3));
      expect(ring.dropped, 2);
      expect(ring.last(2), hasLength(2));
    });

    test('codes come from typed fields, never from messages', () {
      expect(AppErrorRing.codeOf(const ProviderException(ProviderErrorKind.network, 'x')), 'network');
      expect(AppErrorRing.codeOf(McpHttpStatusException(503, body: 'secret body')), 'http_503');
      expect(AppErrorRing.codeOf(const SocketException('x', osError: OSError('refused', 111))), 'os_111');
      expect(AppErrorRing.codeOf(StateError('/home/alice')), isNull);
      expect(AppErrorRing.typeNameOf(StateError('x')), 'StateError');
    });

    test('a bad source name is replaced', () {
      final ring = AppErrorRing()..record(StateError('x'), source: 'Has Spaces /home/alice');
      expect(ring.records.single.source, 'app');
    });
  });

  test('the provider error codes map MCP error strings to short categories', () {
    expect(DiagnosticsCollector.errorCodeOf('McpAuthRequiredException: needs sign in'), 'auth_required');
    expect(DiagnosticsCollector.errorCodeOf('SocketException: Failed host lookup: secret.host'), 'dns');
    expect(DiagnosticsCollector.errorCodeOf('McpTimeoutException: took longer than 30s'), 'timeout');
    expect(DiagnosticsCollector.errorCodeOf('McpRpcException: nope (code -32602)'), 'rpc_-32602');
    expect(DiagnosticsCollector.errorCodeOf('whatever'), 'other');
    expect(DiagnosticsCollector.errorTypeOf('McpTimeoutException: x'), 'McpTimeoutException');
    expect(DiagnosticsCollector.errorTypeOf('lower case: x'), isNull);
  });
}

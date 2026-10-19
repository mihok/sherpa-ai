import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/mcp/input/sampling.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show InferencePriority;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../inference/support/local_rig.dart';
import 'support/input_fakes.dart';

void main() {
  late ScriptedModelProvider model;
  late FakeProviderRegistry registry;
  late McpSamplingService service;

  setUp(() {
    model = ScriptedModelProvider();
    registry = FakeProviderRegistry({'scripted': model});
    service = McpSamplingService(registry: registry, defaultModel: () => defaultChoice);
  });

  test('runs with the capped maxTokens, no tools, only the server messages, the edited prompt', () async {
    final r = samplingRequest(text: 'Original question', maxTokens: 4000, includeContext: 'allServers', systemPrompt: 'Be brief.');
    final c = await service.run(request: r, model: defaultChoice, maxTokens: 256, editedPrompt: 'Edited question');
    expect(c.text, 'Paris.');
    expect(c.stopReason, 'endTurn');
    expect(c.model, defaultChoice);
    final req = model.requests.single;
    expect(req.modelId, 'm1');
    expect(req.tools, isEmpty, reason: 'sampling never gets tools');
    expect(req.params.maxOutputTokens, 256);
    expect(req.params.temperature, isNull, reason: 'sampling parameters are ignored');
    expect(req.systemPrompt, 'Be brief.');
    expect(req.messages, hasLength(1), reason: 'no conversation context, whatever includeContext says');
    expect((req.messages.single.content.single as TextPart).text, 'Edited question');
    expect(req.messages.single.role, Role.user);
    expect(c.priority, isNull, reason: 'remote providers run as they are');
  });

  test('cuts off answers beyond the limit and reports maxTokens', () async {
    model.reply = List.filled(400, 'word').join(' ');
    final c = await service.run(request: samplingRequest(), model: defaultChoice, maxTokens: 20);
    expect(c.stopReason, 'maxTokens');
    expect(c.text.length, lessThanOrEqualTo(80));
  });

  test('provider failures become SamplingException; an unknown provider too', () async {
    model.error = const ProviderException(ProviderErrorKind.auth, 'bad key');
    await expectLater(
      service.run(request: samplingRequest(), model: defaultChoice, maxTokens: 20),
      throwsA(isA<SamplingException>().having((e) => e.message, 'message', 'bad key')),
    );
    await expectLater(
      service.run(request: samplingRequest(), model: const ModelChoice(providerId: 'nope', modelId: 'x'), maxTokens: 20),
      throwsA(isA<SamplingException>()),
    );
  });

  test('cancelling stops the run', () async {
    final cancel = CancellationToken()..cancel();
    await expectLater(
      service.run(request: samplingRequest(), model: defaultChoice, maxTokens: 20, cancel: cancel),
      throwsA(isA<CancelledException>()),
    );
  });

  test('estimates and the model choice order: server choice, chat model, app default', () {
    final r = samplingRequest(text: 'x' * 400, systemPrompt: 'y' * 40);
    final e = service.estimate(r, maxTokens: 100);
    expect(e.inputTokens, greaterThan(90));
    expect(e.totalTokens, e.inputTokens + 100);
    expect(service.estimate(r, maxTokens: 100, editedPrompt: 'short').inputTokens, lessThan(e.inputTokens));
    const server = ModelChoice(providerId: 'a', modelId: 'server');
    const chat = ModelChoice(providerId: 'b', modelId: 'chat');
    expect(service.modelFor(serverChoice: server, chatModel: chat), server);
    expect(service.modelFor(chatModel: chat), chat);
    expect(service.modelFor(), defaultChoice);
    expect(McpSamplingService.editableIndex(r), 0);
  });

  test('on-device models run at background priority', () async {
    // Whatever the view maps a provider to is what runs.
    final local = ScriptedModelProvider(id: 'local', location: ExecutionLocation.onDevice);
    final seen = <ModelProvider>[];
    final s = McpSamplingService(
      registry: FakeProviderRegistry({'local': local}),
      defaultModel: () => null,
      view: (p) {
        seen.add(p);
        return (p, p.info.location == ExecutionLocation.onDevice ? InferencePriority.background : null);
      },
    );
    final c = await s.run(request: samplingRequest(), model: const ModelChoice(providerId: 'local', modelId: 'm1'), maxTokens: 50);
    expect(seen.single, same(local));
    expect(c.priority, InferencePriority.background);
    expect(c.location, ExecutionLocation.onDevice);

    // The default view: the built-in local provider gets its background view.
    final rig = await LocalRig.create();
    addTearDown(rig.dispose);
    final provider = LocalModelProvider(rig.local);
    final (viewed, priority) = backgroundSamplingView(provider);
    expect(priority, InferencePriority.background);
    expect(viewed, isNot(same(provider)));
    expect(viewed.info.id, localProviderId);
    final (remote, none) = backgroundSamplingView(model);
    expect(remote, same(model));
    expect(none, isNull);
  });

  test('rate limiter: a sliding minute per server', () {
    final clock = FakeClock(DateTime.utc(2026, 10, 19, 12));
    final l = SamplingRateLimiter(clock: clock);
    expect(l.tryAcquire('a', 2), isTrue);
    expect(l.tryAcquire('a', 2), isTrue);
    expect(l.tryAcquire('a', 2), isFalse);
    expect(l.tryAcquire('b', 2), isTrue, reason: 'per server');
    clock.advance(const Duration(seconds: 61));
    expect(l.tryAcquire('a', 2), isTrue);
  });

  test('the request carries assistant turns and non-text content through', () async {
    final r = McpSamplingRequest.fromJson({
      'messages': [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 'Hi'},
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'Hello'},
          ],
        },
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 'And?'},
        },
      ],
      'maxTokens': 10,
    });
    expect(McpSamplingService.editableIndex(r), 2);
    await service.run(request: r, model: defaultChoice, maxTokens: 10, editedPrompt: 'And then?');
    final msgs = model.requests.single.messages;
    expect([for (final m in msgs) m.role], [Role.user, Role.assistant, Role.user]);
    expect((msgs.last.content.single as TextPart).text, 'And then?');
    expect((msgs.first.content.single as TextPart).text, 'Hi');
  });
}

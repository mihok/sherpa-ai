import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import 'support/local_chat_rig.dart';
import 'support/local_rig.dart' show libraryModel;

void main() {
  late LocalChatRig rig;
  late FakeEngineHost host;

  setUp(() async {
    host = FakeEngineHost(eventDelay: const Duration(milliseconds: 1))
      ..defaultScript = (_) => fakeReply('Hello from this phone, no network needed.');
    rig = await LocalChatRig.create(hostFactory: ({crashBreadcrumbPath}) async => host);
  });

  tearDown(() => rig.dispose());

  test('choosing a library model runs a chat turn through the chat controller and AgentRunner', () async {
    await rig.library.add(libraryModel('m1', name: 'Qwen3 0.6B'));
    expect((await rig.registry.models(localProviderId)).single.displayName, 'Qwen3 0.6B');

    final chat = await rig.openNewChat();
    const choice = ModelChoice(providerId: localProviderId, modelId: 'm1');
    await chat.changeModel(choice);
    var state = rig.stateOf(chat);
    expect(state.availability, ProviderAvailability.ready);
    expect(state.model!.choice, choice);
    expect(state.model!.location, ExecutionLocation.onDevice, reason: 'the privacy badge reads on device');
    expect(state.model!.providerName, kLocalProviderName);
    expect(state.model!.modelName, 'Qwen3 0.6B');

    await chat.send('Hi there');
    state = rig.stateOf(chat);
    expect(state.error, isNull);
    expect(state.status, ChatRunStatus.idle);
    expect(rig.streamed.length, greaterThan(1), reason: 'the reply streamed in deltas');

    final path = await rig.path(chat);
    expect(path.map((m) => m.role), [Role.user, Role.assistant]);
    expect(path.last.text, 'Hello from this phone, no network needed.');
    expect(path.last.providerId, localProviderId);
    expect(path.last.modelId, 'm1');

    // The engine got the user's message, and the runner counted exactly
    // (the runner extras: engine counter warmed in one batch per request).
    expect(host.requests.single, contains('Hi there'));
    expect(host.countBatchCalls, greaterThan(0));
    expect(rig.local.loadedModelId, 'm1');
    expect(host.loads.single.path, rig.library.layout.libraryPath('imported/m1/model.gguf'));
  });

  test('a local default model is used by new chats', () async {
    await rig.library.add(libraryModel('m1'));
    await rig.container.read(preferencesProvider).setDefaultModel(const ModelChoice(providerId: localProviderId, modelId: 'm1'));
    final chat = await rig.openNewChat();
    final state = rig.stateOf(chat);
    expect(state.model!.providerId, localProviderId);
    expect(state.model!.location, ExecutionLocation.onDevice);
    await chat.send('Hello');
    expect((await rig.path(chat)).last.text, 'Hello from this phone, no network needed.');
  });

  test('an unavailable engine fails the turn with the reason instead of crashing', () async {
    host.startError = const EngineUnavailableException('no engine library in this build');
    await rig.library.add(libraryModel('m1'));
    final chat = await rig.openNewChat();
    await chat.changeModel(const ModelChoice(providerId: localProviderId, modelId: 'm1'));
    expect(rig.stateOf(chat).model!.location, ExecutionLocation.onDevice);
    await chat.send('Hello');
    final state = rig.stateOf(chat);
    expect(state.error, isNotNull);
    expect(state.error!.detail, contains('no engine library in this build'));
  });
}

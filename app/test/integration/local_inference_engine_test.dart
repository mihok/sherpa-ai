// One chat turn on the real engine through the app's own wiring:
// localInferenceOverrides → LocalProviderRegistry → LocalModelProvider →
// LlamaCppProvider → the production engine host (FFI on this host), driven
// by the real chat controller and AgentRunner.
//
// Runs only when both are set (skips cleanly otherwise):
//   SHERPA_ENGINE_LIB=/opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so
//   SHERPA_TEST_MODEL=/opt/models/Qwen3-0.6B-Q4_K_M.gguf
//   cd app && flutter test --no-pub test/integration/local_inference_engine_test.dart
@Tags(['engine'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../services/inference/support/local_chat_rig.dart';

String? _env(String name) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? null : v;
}

String? _skipReason() {
  final lib = _env('SHERPA_ENGINE_LIB');
  final model = _env('SHERPA_TEST_MODEL');
  if (lib == null || model == null) return 'set SHERPA_ENGINE_LIB and SHERPA_TEST_MODEL to run the real engine';
  if (!File(lib).existsSync()) return 'SHERPA_ENGINE_LIB does not exist: $lib';
  if (!File(model).existsSync()) return 'SHERPA_TEST_MODEL does not exist: $model';
  return null;
}

int get _threads => int.tryParse(Platform.environment['SHERPA_TEST_THREADS'] ?? '') ?? 2;

void main() {
  final skip = _skipReason();

  test('imports a GGUF, chooses it and streams a reply from the real engine', () async {
    final rig = await LocalChatRig.create(
      hostFactory: productionHostFactory,
      agentConfig: const AgentConfig(
        maxSteps: 2,
        params: GenerationParams(temperature: 0, seed: 42, maxOutputTokens: 48, reasoning: ReasoningEffort.off),
      ),
      sessionDefaults: SessionConfig(nThreads: _threads, nThreadsBatch: _threads, seed: 42),
      // The default ContextSettings reserve 2048 tokens for the reply.
      maxContext: 4096,
    );
    addTearDown(rig.dispose);

    // Import, as "Add a model file…" does: header check, copy, SHA-256.
    final outcome = await rig.library.importFile(PathModelFile(File(_env('SHERPA_TEST_MODEL')!)));
    final model = switch (outcome) {
      Imported(:final model) => model,
      AlreadyImported(:final model) => model,
      ImportRefused(:final reason) => fail('import refused: $reason'),
    };
    expect(model.files.single.sha256, isNotNull);

    final status = await rig.local.start();
    expect(status.state, LocalEngineState.ready, reason: status.reason);
    expect(rig.local.host!.kind, EngineHostKind.inProcessFfi);
    expect(rig.local.lifecycle!.spec(model.id)!.identity, 'sha256:${model.files.single.sha256}');

    final listed = await rig.registry.models(localProviderId);
    expect(listed.map((d) => d.id), contains(model.id));

    final chat = await rig.openNewChat();
    await chat.changeModel(localModelChoiceFor(model.id));
    final selection = rig.stateOf(chat).model!;
    expect(selection.location, ExecutionLocation.onDevice);
    expect(selection.providerName, kLocalProviderName);

    await chat.send('Reply with one short sentence: what is the capital of France?');
    final state = rig.stateOf(chat);
    expect(state.error, isNull, reason: state.error?.detail);
    expect(state.lastOutcome, RunOutcome.completed);
    expect(rig.streamed, isNotEmpty, reason: 'the reply streamed');

    final path = await rig.path(chat);
    final reply = path.last;
    expect(reply.role, Role.assistant);
    expect(reply.providerId, localProviderId);
    expect(reply.text.trim(), isNotEmpty);
    // ignore: avoid_print
    print('engine reply: ${reply.text.trim()}');
    expect(reply.usage?.outputTokens ?? 0, greaterThan(0));
    expect(rig.local.loadedModelId, model.id);
    expect(rig.local.lifecycle!.loaded!.sessionInfo.nCtx, lessThanOrEqualTo(4096));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}

ModelChoice localModelChoiceFor(String id) => ModelChoice(providerId: localProviderId, modelId: id);

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import '../../features/chat/support/harness.dart';

/// Gemini Nano is foreground only: a chat run that reaches it while Sherpa
/// is not on screen must end with the reason in front of the user, never
/// hang or fail silently — and nothing may reach AICore.
void main() {
  late FakeLiteRtBackend backend;
  late FakeForeground fg;
  late ChatHarness h;

  setUp(() async {
    backend = FakeLiteRtBackend();
    fg = FakeForeground(foreground: false);
    final nano = GeminiNanoProvider(
      backend: backend,
      foreground: fg,
      id: geminiNanoProviderId,
      displayName: onDeviceProviderName(geminiNanoProviderId)!,
    );
    h = ChatHarness(configured: false, providers: {geminiNanoProviderId: nano});
    await h.store.putSession(SessionRecord(
      id: kSession,
      title: defaultSessionTitle,
      createdAt: h.clock.now(),
      updatedAt: h.clock.now(),
      providerId: geminiNanoProviderId,
      modelId: GeminiNanoProvider.modelId,
    ));
  });

  tearDown(() async {
    h.dispose();
    await backend.dispose();
    await fg.dispose();
  });

  test('a background request to Gemini Nano ends the run with the foreground-only reason', () async {
    final c = await h.open();
    expect(h.state.model?.providerName, 'Gemini Nano');
    expect(h.state.model?.location, ExecutionLocation.onDevice);

    await c.send('Summarize my notes');
    await h.until(() => h.state.error != null);
    final error = h.state.error!;
    expect(error.title, contains('Gemini Nano'));
    expect(error.detail, contains(kNanoBackgroundMessage));
    expect(backend.nanoRequests, isEmpty, reason: 'refused before anything reached AICore');
  });

  test('in the foreground the same chat runs on Gemini Nano', () async {
    fg.foreground = true;
    backend.scripts.add((s) {
      s.text('Here is a summary.');
      s.done();
    });
    final c = await h.open();
    await c.send('Summarize my notes');
    await h.until(() => backend.nanoRequests.isNotEmpty && h.state.error == null && !h.state.isRunActive);
    expect(backend.nanoRequests, hasLength(1));
    expect(h.state.error, isNull);
  });
}

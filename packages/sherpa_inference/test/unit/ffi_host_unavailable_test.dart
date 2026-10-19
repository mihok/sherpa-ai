import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

/// No engine library at all (an Android build without
/// native/llama/out/android/jniLibs, an iOS build without the xcframework):
/// the host refuses to start and the provider says "engine unavailable".
void main() {
  test('a missing engine library is "engine unavailable", not a crash', () async {
    final host = FfiEngineHost(libraryPath: '/nonexistent/libsherpa_engine.so');
    await expectLater(
        host.start(),
        throwsA(isA<EngineUnavailableException>()
            .having((e) => e.message, 'message', contains('/nonexistent/libsherpa_engine.so'))));
    final lifecycle = ModelLifecycleManager(host: host)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final provider = LlamaCppProvider(lifecycle: lifecycle);
    await expectLater(
        provider.stream(const ModelRequest(modelId: 'm', messages: [])).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.unsupported)
            .having((e) => e.message, 'message', contains('unavailable'))));
    await expectLater(provider.capabilities('m'), throwsA(isA<ProviderException>()));
    await host.dispose();
  });

  test('the bindings look up exactly the functions the header declares', () {
    final header = File('../../native/engine/include/sherpa_engine.h');
    if (!header.existsSync()) return; // package used outside the repo
    final declared = {
      for (final m in RegExp(r'SE_API\s[^;{]*?\b(se_[a-z0-9_]+)\s*\(').allMatches(header.readAsStringSync())) m[1]!,
    };
    final bound = {
      for (final m in RegExp(r">\(\s*'(se_[a-z0-9_]+)'\)")
          .allMatches(File('lib/src/ffi/bindings.dart').readAsStringSync()))
        m[1]!,
    };
    expect(declared, hasLength(39));
    expect(bound, declared);
  });
}

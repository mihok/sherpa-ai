import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/src/ffi/bindings.dart';

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
    final text = header.readAsStringSync();
    final declared = {
      for (final m in RegExp(r'SE_API\s[^;{]*?\b(se_[a-z0-9_]+)\s*\(').allMatches(text)) m[1]!,
    };
    final source = File('lib/src/ffi/bindings.dart').readAsStringSync();
    final bound = {
      for (final m in RegExp(r">\(\s*'(se_[a-z0-9_]+)'\)").allMatches(source)) m[1]!,
    };
    expect(declared, hasLength(SherpaEngineBindings.functionCount));
    expect(bound, declared);
    // The 1.1 additions are optional (looked up only when present), so a 1.0
    // engine still loads; everything else is required.
    final optional = {
      for (final m in RegExp(r"providesSymbol\('(se_[a-z0-9_]+)'\)").allMatches(source)) m[1]!,
    };
    expect(optional, {'se_abi_minor', 'se_generate_params_init', 'se_generate_start_ex'});
    expect(declared.length - optional.length, SherpaEngineBindings.requiredFunctionCount);
    // The constants follow the header.
    expect(RegExp(r'#define SE_ABI_VERSION (\d+)u').firstMatch(text)![1], '$kSeAbiVersion');
    expect(RegExp(r'#define SE_ABI_MINOR (\d+)u').firstMatch(text)![1], '$kSeAbiMinor');
  });
}

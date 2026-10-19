import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `package:sherpa_inference/engine.dart` is the entry point for pure-Dart
/// hosts (`dart run`, `dart test`): nothing it reaches may import Flutter.
void main() {
  final directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

  /// Every library of this package [entry] reaches through imports and
  /// exports, with the package-external URIs each one names.
  Map<String, List<String>> reach(String entry) {
    final out = <String, List<String>>{};
    final queue = [p.normalize(entry)];
    while (queue.isNotEmpty) {
      final file = queue.removeLast();
      if (out.containsKey(file)) continue;
      final external = <String>[];
      out[file] = external;
      for (final m in directive.allMatches(File(file).readAsStringSync())) {
        final uri = m[1]!;
        if (uri.startsWith('package:sherpa_inference/')) {
          queue.add(p.normalize(p.join('lib', uri.substring('package:sherpa_inference/'.length))));
        } else if (uri.startsWith('package:') || uri.startsWith('dart:')) {
          external.add(uri);
        } else {
          queue.add(p.normalize(p.join(p.dirname(file), uri)));
        }
      }
    }
    return out;
  }

  test('engine.dart reaches no Flutter import', () {
    final graph = reach('lib/engine.dart');
    expect(graph.keys, contains(p.normalize('lib/src/provider/llama_cpp_provider.dart')));
    expect(graph.keys, contains(p.normalize('lib/src/engine/ffi_engine_host.dart')));
    for (final e in graph.entries) {
      for (final uri in e.value) {
        expect(uri.startsWith('package:flutter') || uri == 'dart:ui', isFalse, reason: '${e.key} imports $uri');
      }
    }
  });

  test('the main library still exports the process host (and so needs Flutter)', () {
    final graph = reach('lib/sherpa_inference.dart');
    expect(graph.keys, contains(p.normalize('lib/engine.dart')));
    expect(graph.values.expand((u) => u), contains('package:flutter/services.dart'));
  });
}

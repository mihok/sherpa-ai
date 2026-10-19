/// Locates the package's data files (scenarios, corpora, baselines).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// The `packages/sherpa_evals` directory, from the package config (works
/// under `dart run` and `dart test` from any working directory), or
/// [override] / `$SHERPA_EVALS_ROOT`.
String evalsPackageRoot({String? override}) {
  final env = override ?? Platform.environment['SHERPA_EVALS_ROOT'];
  if (env != null && env.isNotEmpty) return p.normalize(p.absolute(env));
  final lib = Isolate.resolvePackageUriSync(Uri.parse('package:sherpa_evals/sherpa_evals.dart'));
  if (lib == null) throw StateError('cannot resolve package:sherpa_evals (run from the Sherpa workspace)');
  return p.dirname(p.dirname(lib.toFilePath()));
}

/// The repository root (two levels above the package).
String repoRoot() => p.dirname(p.dirname(evalsPackageRoot()));

String dataPath(String relative) => p.join(evalsPackageRoot(), 'data', relative);

Object? readJson(String path) => jsonDecode(File(path).readAsStringSync());

Map<String, Object?> readJsonObject(String path) => (readJson(path)! as Map).cast<String, Object?>();

/// `data/<relative>` as a JSON object.
Map<String, Object?> loadData(String relative) => readJsonObject(dataPath(relative));

List<Map<String, Object?>> objectList(Object? v) => [for (final e in (v as List?) ?? const []) (e as Map).cast<String, Object?>()];

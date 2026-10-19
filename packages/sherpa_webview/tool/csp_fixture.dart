// Regenerates test/web/fixtures/policies.json from its inputs with the real
// CSP builder:  dart run tool/csp_fixture.dart
// test/csp_test.dart fails when the checked-in goldens drift from the
// builder, so a policy change is always reviewed in the fixture diff.
import 'dart:convert';
import 'dart:io';

import 'package:sherpa_webview/src/policy/csp.dart';

void main() {
  final file = File('test/web/fixtures/policies.json');
  final doc = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  final cases = (doc['cases']! as List).cast<Map<String, Object?>>();
  for (final c in cases) {
    final declared = DeclaredDomains.fromCsp((c['csp']! as Map).cast<String, Object?>());
    final granted = {...(c['granted']! as List).cast<String>()};
    final csp = McpAppCsp.build(declared.grant(granted));
    c['policy'] = csp.policy;
    c['allowedOrigins'] = csp.allowedOrigins;
    c['rejected'] = declared.rejected;
  }
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
  stdout.writeln('updated ${cases.length} cases');
}

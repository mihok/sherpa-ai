import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

void main() {
  final valid = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  test('valid names map to themselves', () {
    final m = ToolNameMapper(['get_weather', 'github__create_issue', 'a-b']);
    for (final n in ['get_weather', 'github__create_issue', 'a-b']) {
      expect(m.toWire(n), n);
      expect(m.fromWire(n), n);
    }
    expect(m.rewritesAny, isFalse);
  });

  test('invalid characters are replaced and mapped back', () {
    final m = ToolNameMapper(['files.read', 'srv/list items', 'émoji✓']);
    for (final n in ['files.read', 'srv/list items', 'émoji✓']) {
      final w = m.toWire(n);
      expect(w, matches(valid));
      expect(m.fromWire(w), n);
    }
    expect(m.toWire('files.read'), 'files_read');
  });

  test('collisions after sanitizing get distinct, stable names', () {
    final names = ['a.b', 'a/b', 'a_b', 'a b'];
    final m = ToolNameMapper(names);
    final wires = names.map(m.toWire).toList();
    expect(wires.toSet(), hasLength(4));
    // The already-valid name keeps its own spelling.
    expect(m.toWire('a_b'), 'a_b');
    for (final n in names) {
      expect(m.fromWire(m.toWire(n)), n);
    }
    // Order independence: the same set in another order maps identically.
    final m2 = ToolNameMapper(names.reversed);
    for (final n in names) {
      expect(m2.toWire(n), m.toWire(n));
    }
  });

  test('long names are truncated with a hash and stay unique', () {
    final a = 'server_${'x' * 80}_alpha';
    final b = 'server_${'x' * 80}_beta';
    final m = ToolNameMapper([a, b]);
    expect(m.toWire(a), matches(valid));
    expect(m.toWire(b), matches(valid));
    expect(m.toWire(a), isNot(m.toWire(b)));
    expect(m.fromWire(m.toWire(b)), b);
  });

  test('unknown names are sanitized deterministically and passed back unchanged', () {
    final m = ToolNameMapper(['known']);
    expect(m.toWire('removed.tool'), 'removed_tool');
    expect(m.fromWire('mystery'), 'mystery');
    expect(ToolNameMapper.sanitize(''), 'tool');
  });

  test('model-mangled names resolve only when unambiguous', () {
    final m = ToolNameMapper(['get_weather', 'Search', 'search_docs']);
    expect(m.fromWire('functions.get_weather'), 'get_weather');
    expect(m.fromWire('GET_WEATHER'), 'get_weather');
    expect(m.fromWire('search'), 'Search');
    final ambiguous = ToolNameMapper(['Run', 'run']);
    expect(ambiguous.fromWire('RUN'), 'RUN');
  });
}

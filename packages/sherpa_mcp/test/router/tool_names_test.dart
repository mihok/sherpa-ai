import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  final valid = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  group('McpToolNamer', () {
    test('clean ids and names are kept: <server>__<tool>', () {
      expect(McpToolNamer.namespace('github'), 'github');
      expect(McpToolNamer.modelName('github', 'create_issue'), 'github__create_issue');
      expect(McpToolNamer.modelName('fs', 'read-file'), 'fs__read-file');
    });

    test('unclean names are sanitized and always hashed (never collide with clean ones)', () {
      final dotted = McpToolNamer.modelName('fs', 'files.read');
      final clean = McpToolNamer.modelName('fs', 'files_read');
      expect(clean, 'fs__files_read');
      expect(dotted, startsWith('fs__files_read_'));
      expect(dotted, isNot(clean));
      expect(dotted, matches(valid));
      // Different originals that sanitize alike still differ.
      expect(McpToolNamer.modelName('fs', 'files/read'), isNot(dotted));
      expect(McpToolNamer.modelName('fs', 'files read'), matches(valid));
    });

    test('server ids with __, dots, or over-long ones get a hashed namespace without __', () {
      for (final id in ['my__srv', 'my.server', 'a' * 40, '_x_', '!!!', 'Ünïcode']) {
        final ns = McpToolNamer.namespace(id);
        expect(ns, isNot(contains('__')), reason: id);
        expect(ns.length, lessThanOrEqualTo(McpToolNamer.maxNamespaceLength), reason: id);
        expect(ns, matches(RegExp(r'^[a-zA-Z0-9_-]+$')), reason: id);
        expect(ns.endsWith('_'), isFalse, reason: id);
      }
      expect(McpToolNamer.namespace('my.server'), isNot(McpToolNamer.namespace('my_server')));
      // "a" + "b__c" vs "a__b" + "c" cannot meet: the second namespace is hashed.
      final one = McpToolNamer.modelName(McpToolNamer.namespace('a'), 'b__c');
      final two = McpToolNamer.modelName(McpToolNamer.namespace('a__b'), 'c');
      expect(one, isNot(two));
    });

    test('long names are shortened deterministically with a hash suffix, within 64 chars', () {
      final long = 'get_${'very_' * 20}long_tool_name';
      final a = McpToolNamer.modelName('server', long);
      final b = McpToolNamer.modelName('server', long);
      expect(a, b);
      expect(a.length, lessThanOrEqualTo(64));
      expect(a, matches(valid));
      expect(a, startsWith('server__get_very_'));
      final other = McpToolNamer.modelName('server', '${long}2');
      expect(other, isNot(a));
    });

    test('names are a function of (namespace, tool) only: adding tools never renames existing ones', () {
      final before = McpToolNamer.assign({
        const McpToolKey('fs', 'files.read'): 'fs',
        const McpToolKey('fs', 'write'): 'fs',
      });
      final after = McpToolNamer.assign({
        const McpToolKey('fs', 'files.read'): 'fs',
        const McpToolKey('fs', 'write'): 'fs',
        const McpToolKey('fs', 'files_read'): 'fs',
        const McpToolKey('gh', 'write'): 'gh',
      });
      expect(after[const McpToolKey('fs', 'files.read')], before[const McpToolKey('fs', 'files.read')]);
      expect(after[const McpToolKey('fs', 'write')], 'fs__write');
      expect(after[const McpToolKey('gh', 'write')], 'gh__write');
      expect(after.values.toSet(), hasLength(4));
    });

    test('assign resolves a literal collision deterministically', () {
      // Two servers given the SAME namespace by a misconfigured alias.
      final m = McpToolNamer.assign({
        const McpToolKey('a', 'x'): 'dup',
        const McpToolKey('b', 'x'): 'dup',
      });
      expect(m.values.toSet(), {'dup__x', 'dup__x_2'});
      expect(m[const McpToolKey('a', 'x')], 'dup__x', reason: 'sorted key order decides');
    });
  });

  group('McpToolKey', () {
    test('round-trips through its encoding, even with slashes', () {
      const k = McpToolKey('srv/1', 'a/b c');
      expect(McpToolKey.parse(k.encoded), k);
      expect(k.encoded, isNot(contains(' ')));
      expect(() => McpToolKey.parse('nokey'), throwsFormatException);
    });
  });
}

import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('header value encoding (streamable-http.md §Value Encoding vectors)', () {
    // Verbatim from the spec's table (R01 §4.1).
    const vectors = {
      'us-west1': 'us-west1',
      'Hello, 世界': '=?base64?SGVsbG8sIOS4lueVjA==?=',
      ' padded ': '=?base64?IHBhZGRlZCA=?=',
      'line1\nline2': '=?base64?bGluZTEKbGluZTI=?=',
      '=?base64?literal?=': '=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=',
    };
    for (final e in vectors.entries) {
      test('${e.key.replaceAll('\n', r'\n')} → ${e.value}', () {
        expect(encodeMcpHeaderValue(e.key), e.value);
        expect(decodeMcpHeaderValue(e.value), e.key);
      });
    }

    test('other unsafe values are wrapped; tab and plain ASCII pass through', () {
      expect(encodeMcpHeaderValue('a\tb'), 'a\tb');
      expect(encodeMcpHeaderValue('café'), startsWith('=?base64?'));
      expect(encodeMcpHeaderValue('\u0001'), startsWith('=?base64?'));
      expect(encodeMcpHeaderValue(''), '=?base64??=');
      // Only the full sentinel shape triggers wrapping.
      expect(encodeMcpHeaderValue('=?base64?abc'), '=?base64?abc');
      expect(encodeMcpHeaderValue('file:///project/a b.txt'), 'file:///project/a b.txt');
    });
  });

  group('x-mcp-header scan (tools.md §x-mcp-header)', () {
    JsonMapX schema(Map<String, Object?> props) => {'type': 'object', 'properties': props};

    test('collects valid declarations including nested properties', () {
      final scan = scanMcpHeaderParams(schema({
        'region': {'type': 'string', 'x-mcp-header': 'Region'},
        'opts': {
          'type': 'object',
          'properties': {
            'dry': {'type': 'boolean', 'x-mcp-header': 'Dry-Run'},
          },
        },
        'n': {'type': 'integer', 'x-mcp-header': 'N'},
      }));
      expect(scan.isValid, isTrue);
      expect([for (final p in scan.params) '${p.path.join('.')}=${p.headerName}'],
          ['region=Region', 'opts.dry=Dry-Run', 'n=N']);
    });

    final invalid = <String, JsonMapX>{
      'empty name': schema({
        'a': {'type': 'string', 'x-mcp-header': ''},
      }),
      'not a token (space)': schema({
        'a': {'type': 'string', 'x-mcp-header': 'Bad Name'},
      }),
      'control character': schema({
        'a': {'type': 'string', 'x-mcp-header': 'Bad\nName'},
      }),
      'number type is forbidden': schema({
        'a': {'type': 'number', 'x-mcp-header': 'A'},
      }),
      'object type': schema({
        'a': {'type': 'object', 'x-mcp-header': 'A'},
      }),
      'case-insensitive duplicate': schema({
        'a': {'type': 'string', 'x-mcp-header': 'Region'},
        'b': {'type': 'string', 'x-mcp-header': 'REGION'},
      }),
      'under items': schema({
        'list': {
          'type': 'array',
          'items': {'type': 'string', 'x-mcp-header': 'Item'},
        },
      }),
      'under anyOf': {
        'type': 'object',
        'anyOf': [
          {
            'properties': {
              'a': {'type': 'string', 'x-mcp-header': 'A'},
            },
          },
        ],
      },
      'under \$defs': {
        'type': 'object',
        r'$defs': {
          'x': {'type': 'string', 'x-mcp-header': 'X'},
        },
      },
      'on the root': {'type': 'object', 'x-mcp-header': 'Root'},
    };
    for (final e in invalid.entries) {
      test('rejects: ${e.key}', () {
        final scan = scanMcpHeaderParams(e.value);
        expect(scan.isValid, isFalse, reason: e.key);
        expect(scan.invalidReason, isNotEmpty);
      });
    }

    test('builds Mcp-Param headers with canonical values and omits absent/null', () {
      final scan = scanMcpHeaderParams(schema({
        'region': {'type': 'string', 'x-mcp-header': 'Region'},
        'greeting': {'type': 'string', 'x-mcp-header': 'Greeting'},
        'count': {'type': 'integer', 'x-mcp-header': 'Count'},
        'dry': {'type': 'boolean', 'x-mcp-header': 'Dry'},
        'missing': {'type': 'string', 'x-mcp-header': 'Missing'},
        'nul': {'type': 'string', 'x-mcp-header': 'Nul'},
        'big': {'type': 'integer', 'x-mcp-header': 'Big'},
      }));
      final h = buildMcpParamHeaders(scan.params, {
        'region': 'us-west1',
        'greeting': 'Hello, 世界',
        'count': 42.0,
        'dry': false,
        'nul': null,
        'big': 9007199254740993,
      });
      expect(h, {
        'Mcp-Param-Region': 'us-west1',
        'Mcp-Param-Greeting': '=?base64?SGVsbG8sIOS4lueVjA==?=',
        'Mcp-Param-Count': '42',
        'Mcp-Param-Dry': 'false',
      });
    });

    test('a type mismatch is omitted rather than sent malformed', () {
      final scan = scanMcpHeaderParams(schema({
        'count': {'type': 'integer', 'x-mcp-header': 'Count'},
      }));
      expect(buildMcpParamHeaders(scan.params, {'count': 'forty'}), isEmpty);
      expect(buildMcpParamHeaders(scan.params, {'count': 1.5}), isEmpty);
    });
  });

  test('reserved header names cannot be configured', () {
    for (final n in ['Mcp-Session-Id', 'mcp-method', 'MCP-Protocol-Version', 'Mcp-Param-X', 'Accept', 'Last-Event-ID']) {
      expect(McpHeaders.isReserved(n), isTrue, reason: n);
    }
    expect(McpHeaders.isReserved('X-Tenant'), isFalse);
  });

  test('reserved _meta prefixes', () {
    expect(McpMetaKeys.isReserved('io.modelcontextprotocol/x'), isTrue);
    expect(McpMetaKeys.isReserved('dev.mcp/x'), isTrue);
    expect(McpMetaKeys.isReserved('com.example.mcp/x'), isFalse);
    expect(McpMetaKeys.isReserved('ai.sherpa/x'), isFalse);
    expect(McpMetaKeys.isReserved('plain'), isFalse);
  });
}

typedef JsonMapX = Map<String, Object?>;

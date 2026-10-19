import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart' show JsonMap;
import 'package:sherpa_mcp/sherpa_mcp.dart';

/// A tiny on-device-style Dart MCP server over an [McpMessageChannel].
final class InProcessServer {
  InProcessServer(this.channel, {required this.era, this.silentOnDiscover = false}) {
    _sub = channel.messages.listen(_on);
  }

  final McpMessageChannel channel;
  final McpEra era;

  /// A legacy server that ignores pre-`initialize` requests (probe times out).
  final bool silentOnDiscover;
  late final StreamSubscription<String> _sub;
  final List<JsonMap> received = [];
  final Set<Object?> cancelled = {};
  final Map<String, Completer<Object?>> _pending = {};
  Object? listenId;
  int _n = 0;

  List<String?> get methods => [for (final m in received) m['method'] as String?];

  void _send(JsonMap m) => channel.send(jsonEncode(m));

  void _result(Object? id, JsonMap r) => _send({'jsonrpc': '2.0', 'id': id, 'result': r});

  void _on(String text) {
    final m = (jsonDecode(text) as Map).cast<String, Object?>();
    received.add(m);
    final method = m['method'] as String?;
    final id = m['id'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method == null) {
      _pending.remove('$id')?.complete(m['result'] ?? m['error']);
      return;
    }
    if (method == 'notifications/cancelled') {
      cancelled.add(params['requestId']);
      return;
    }
    if (id == null) return;
    era == McpEra.modern ? _modern(id, method, params) : unawaited(_legacy(id, method, params));
  }

  static const _tools = [
    {
      'name': 'slow',
      'inputSchema': {'type': 'object'},
    },
    {
      'name': 'ask',
      'inputSchema': {'type': 'object'},
    },
  ];

  void _modern(Object? id, String method, JsonMap params) {
    switch (method) {
      case 'server/discover':
        _result(id, {
          'resultType': 'complete',
          'supportedVersions': ['2026-07-28'],
          'capabilities': {
            'tools': {'listChanged': true},
          },
          'ttlMs': 0,
          'cacheScope': 'private',
        });
      case 'tools/list':
        _result(id, {'resultType': 'complete', 'tools': _tools, 'ttlMs': 0, 'cacheScope': 'private'});
      case 'tools/call' when params['name'] == 'slow':
        break; // never answers; waits for notifications/cancelled
      case 'tools/call':
        final responses = params['inputResponses'] as Map?;
        if (responses == null) {
          _result(id, {
            'resultType': 'input_required',
            'inputRequests': {
              'q': {
                'method': 'elicitation/create',
                'params': {
                  'message': 'Proceed?',
                  'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
                },
              },
            },
            'requestState': 's1',
          });
        } else {
          _result(id, {
            'resultType': 'complete',
            'content': [
              {'type': 'text', 'text': '${(responses['q'] as Map)['action']} ${params['requestState']}'},
            ],
          });
        }
      case 'subscriptions/listen':
        listenId = id;
        _send({
          'jsonrpc': '2.0',
          'method': 'notifications/subscriptions/acknowledged',
          'params': {
            '_meta': {McpMetaKeys.subscriptionId: id},
            'notifications': {'toolsListChanged': true},
          },
        });
      default:
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
    }
  }

  /// Modern: a listen-stream notification.
  void notifyToolsChanged() => _send({
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
        'params': {
          '_meta': {McpMetaKeys.subscriptionId: listenId},
        },
      });

  /// Modern stdio: the server tears the listen stream down.
  void endListen() => _send({
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': listenId},
      });

  Future<void> _legacy(Object? id, String method, JsonMap params) async {
    switch (method) {
      case 'server/discover':
        if (silentOnDiscover) return;
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
      case 'initialize':
        _result(id, {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'inproc-legacy', 'version': '1'},
        });
      case 'tools/list':
        _result(id, {'tools': _tools});
      case 'tools/call' when params['name'] == 'slow':
        break;
      case 'tools/call':
        final sid = 'q${++_n}';
        final answer = _pending[sid] = Completer<Object?>();
        _send({
          'jsonrpc': '2.0',
          'id': sid,
          'method': 'elicitation/create',
          'params': {
            'message': 'Proceed?',
            'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
          },
        });
        final r = await answer.future;
        _result(id, {
          'content': [
            {'type': 'text', 'text': '${(r! as Map)['action']}'},
          ],
        });
      default:
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await channel.close();
  }
}

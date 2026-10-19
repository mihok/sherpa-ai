/// Registry that hosts on-device Dart servers for [McpServerManager].
library;

import '../config.dart';
import '../transport/in_process.dart';
import '../transport/transport.dart';
import 'dart_server.dart';

/// Hosts the app's built-in [DartMcpServer]s and hands the manager a fresh
/// in-process transport per connection, so built-ins appear through
/// `McpToolRouter` exactly like remote servers (source kind `onDevice`).
///
/// ```dart
/// final onDevice = OnDeviceServers()
///   ..register(memoryMcpServer(notes), id: 'memory', name: 'Memory')
///   ..register(deviceMcpServer(provider: info), id: 'device', name: 'Device');
/// final manager = McpServerManager(
///   servers: [...onDevice.configs, ...remoteConfigs],
///   transportFactory: onDevice.transportFor,
/// );
/// ```
final class OnDeviceServers {
  final Map<String, DartMcpServer> _servers = {};
  final Map<String, McpServerConfig> _configs = {};

  /// URI scheme of on-device server configs (never dialled).
  static const String scheme = 'sherpa-inprocess';

  /// Registers [server] under the stable [id] (also its tool namespace).
  /// Built-ins are [trusted] by default: they ship with the app, so their
  /// annotations are honest and their definitions change only on update.
  McpServerConfig register(
    DartMcpServer server, {
    required String id,
    required String name,
    bool trusted = true,
    bool enabled = true,
  }) {
    if (_servers.containsKey(id)) throw ArgumentError.value(id, 'id', 'already registered');
    _servers[id] = server;
    return _configs[id] = McpServerConfig(
      id: id,
      name: name,
      url: Uri.parse('$scheme://$id'),
      transport: McpTransportPreference.inProcess,
      trusted: trusted,
      enabled: enabled,
    );
  }

  List<McpServerConfig> get configs => List.unmodifiable(_configs.values);

  DartMcpServer? server(String id) => _servers[id];

  /// An [McpTransportFactory]: a connected in-process pair whose server end
  /// is being served; null for configs this registry does not host.
  McpTransport? transportFor(McpServerConfig config) {
    final server = _servers[config.id];
    if (server == null || config.transport != McpTransportPreference.inProcess) return null;
    final (client, channel) = InProcessTransport.pair();
    server.serve(channel);
    return client;
  }

  /// Ends every session of every hosted server.
  Future<void> close() async {
    for (final s in _servers.values) {
      await s.close();
    }
  }
}

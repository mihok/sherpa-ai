/// Tool definition pins (R11 §9.7 "MCP tool hygiene").
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap, compact;

import '../protocol/json_read.dart';
import '../protocol/primitives.dart';
import 'canonical.dart';
import 'tool_names.dart';

/// Who approved a pinned definition.
enum PinOrigin {
  /// The user approved it (first use of an untrusted server's tool, or a
  /// re-approval from the diff after a change).
  user,

  /// Pinned at first sight because the user trusts the server.
  trustedServer,

  /// An on-device server that ships with the app (its definitions change
  /// only with an app update, so changes are re-pinned automatically).
  builtin,
}

/// The approved definition of one tool, as hashed.
@immutable
final class ToolPin {
  const ToolPin({
    required this.key,
    required this.hash,
    required this.definition,
    required this.approvedAt,
    required this.origin,
  });

  factory ToolPin.fromJson(JsonMap j) => ToolPin(
        key: McpToolKey(reqString(j, 'serverId', 'tool pin'), reqString(j, 'toolName', 'tool pin')),
        hash: reqString(j, 'hash', 'tool pin'),
        definition: reqMap(j, 'definition', 'tool pin'),
        approvedAt: DateTime.parse(reqString(j, 'approvedAt', 'tool pin')),
        origin: PinOrigin.values.where((o) => o.name == j['origin']).firstOrNull ?? PinOrigin.user,
      );

  final McpToolKey key;

  /// `sha256(canonicalJson(definition))`, lower-case hex.
  final String hash;

  /// The pinned subset ([pinnedDefinition]) — kept so a later change can
  /// be shown as a readable diff.
  final JsonMap definition;
  final DateTime approvedAt;
  final PinOrigin origin;

  JsonMap toJson() => {
        'serverId': key.serverId,
        'toolName': key.toolName,
        'hash': hash,
        'definition': definition,
        'approvedAt': approvedAt.toUtc().toIso8601String(),
        'origin': origin.name,
      };
}

/// Where pins live. The app maps this onto its document store (one
/// document per pin keyed by [McpToolKey.encoded]); it is async for that
/// reason. Pins of removed tools are kept on purpose: a tool that
/// disappears and comes back different is a change, not a new tool.
abstract interface class ToolPinStore {
  Future<ToolPin?> get(McpToolKey key);

  Future<List<ToolPin>> forServer(String serverId);

  Future<void> put(ToolPin pin);

  Future<void> remove(McpToolKey key);

  /// Drops every pin of a server the user removed.
  Future<void> removeServer(String serverId);
}

/// [ToolPinStore] in memory, for tests and as a cache in front of storage.
final class InMemoryToolPinStore implements ToolPinStore {
  InMemoryToolPinStore([Iterable<ToolPin> pins = const []]) {
    for (final p in pins) {
      _pins[p.key] = p;
    }
  }

  final Map<McpToolKey, ToolPin> _pins = {};

  List<ToolPin> get all => List.unmodifiable(_pins.values);

  @override
  Future<ToolPin?> get(McpToolKey key) async => _pins[key];

  @override
  Future<List<ToolPin>> forServer(String serverId) async => [
        for (final p in _pins.values)
          if (p.key.serverId == serverId) p,
      ];

  @override
  Future<void> put(ToolPin pin) async => _pins[pin.key] = pin;

  @override
  Future<void> remove(McpToolKey key) async => _pins.remove(key);

  @override
  Future<void> removeServer(String serverId) async => _pins.removeWhere((k, _) => k.serverId == serverId);
}

/// The part of a tool definition that is pinned: `name`, `title`,
/// `description`, `inputSchema`, `outputSchema`, `annotations` (R11 §9.7)
/// plus `_meta.ui` (MCP Apps visibility and resource), because flipping a
/// tool from app-only to model-visible is as security-relevant as a new
/// description. Taken from the raw JSON so unknown annotation keys count.
JsonMap pinnedDefinition(McpTool tool) {
  final raw = tool.raw;
  final ui = asMap(asMap(raw['_meta'])?['ui']);
  final legacyUi = asMap(raw['_meta'])?['ui/resourceUri'];
  return deepCopyMap(compact({
    'name': tool.name,
    'title': raw['title'],
    'description': raw['description'],
    'inputSchema': raw['inputSchema'],
    'outputSchema': raw['outputSchema'],
    'annotations': raw['annotations'],
    'ui': ui ?? (legacyUi == null ? null : {'resourceUri': legacyUi}),
  }));
}

/// `sha256(canonicalJson(pinnedDefinition(tool)))`.
String pinHashOf(JsonMap definition) => sha256Hex(canonicalJson(definition));

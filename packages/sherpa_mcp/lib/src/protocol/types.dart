/// Shared MCP shapes: implementations, icons, annotations, log levels and
/// server capabilities (schema.ts 2026-07-28; L differences noted).
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap, compact;

import 'json_read.dart';
import 'versions.dart';

/// `Implementation` (clientInfo / serverInfo). Self-reported by the peer:
/// display only, never a security decision (basic/index.md §_meta).
@immutable
final class McpImplementation {
  const McpImplementation({
    required this.name,
    required this.version,
    this.title,
    this.description,
    this.websiteUrl,
    this.icons = const [],
  });

  static McpImplementation? tryParse(Object? json) {
    final j = asMap(json);
    final name = asString(j?['name']);
    if (j == null || name == null) return null;
    return McpImplementation(
      name: name,
      version: asString(j['version']) ?? '',
      title: asString(j['title']),
      description: asString(j['description']),
      websiteUrl: asString(j['websiteUrl']),
      icons: McpIcon.listFrom(j['icons']),
    );
  }

  /// Sherpa's default clientInfo.
  static const McpImplementation sherpa = McpImplementation(name: 'sherpa', title: 'Sherpa', version: '0.1.0');

  final String name;
  final String version;
  final String? title;
  final String? description;
  final String? websiteUrl;
  final List<McpIcon> icons;

  String get displayName => title ?? name;

  JsonMap toJson() => compact({
        'name': name,
        'version': version,
        'title': title,
        'description': description,
        'websiteUrl': websiteUrl,
        'icons': icons.isEmpty ? null : [for (final i in icons) i.toJson()],
      });
}

/// `Icon` (basic/index.md §Icons). Rendering hosts MUST reject any scheme
/// other than `https:` and `data:`; [isAllowedScheme] encodes that rule
/// so the UI can skip unsafe icons without re-implementing it.
@immutable
final class McpIcon {
  const McpIcon({required this.src, this.mimeType, this.sizes = const [], this.theme});

  static List<McpIcon> listFrom(Object? json) => [
        for (final j in mapList(json))
          if (asString(j['src']) case final src?)
            McpIcon(
              src: src,
              mimeType: asString(j['mimeType']),
              sizes: stringList(j['sizes']),
              theme: asString(j['theme']),
            ),
      ];

  final String src;
  final String? mimeType;
  final List<String> sizes;

  /// `light` or `dark`.
  final String? theme;

  bool get isAllowedScheme {
    final scheme = Uri.tryParse(src)?.scheme.toLowerCase();
    return scheme == 'https' || scheme == 'data';
  }

  JsonMap toJson() => compact({'src': src, 'mimeType': mimeType, 'sizes': sizes.isEmpty ? null : sizes, 'theme': theme});
}

/// Content `Annotations`: routing hints for UI vs model and context-budget
/// priority. Untrusted hints.
@immutable
final class McpAnnotations {
  const McpAnnotations({this.audience, this.priority, this.lastModified});

  static McpAnnotations? tryParse(Object? json) {
    final j = asMap(json);
    if (j == null) return null;
    return McpAnnotations(
      audience: j['audience'] is List ? stringList(j['audience']) : null,
      priority: asDouble(j['priority']),
      lastModified: asString(j['lastModified']),
    );
  }

  /// `user` and/or `assistant`.
  final List<String>? audience;

  /// 0 (least) … 1 (most important).
  final double? priority;

  /// ISO 8601.
  final String? lastModified;

  bool get forUserOnly => audience != null && audience!.isNotEmpty && !audience!.contains('assistant');

  JsonMap toJson() => compact({'audience': audience, 'priority': priority, 'lastModified': lastModified});
}

/// Syslog-style levels (server/utilities/logging.md), least severe first.
enum McpLogLevel {
  debug,
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency;

  static McpLogLevel? tryParse(Object? v) {
    for (final l in values) {
      if (l.name == v) return l;
    }
    return null;
  }
}

/// `ServerCapabilities`, as reported by `server/discover` (M) or
/// `initialize` (L). [raw] keeps everything for diagnostics.
@immutable
final class McpServerCapabilities {
  const McpServerCapabilities(this.raw);

  static const McpServerCapabilities none = McpServerCapabilities({});

  final JsonMap raw;

  JsonMap? _section(String k) => asMap(raw[k]);

  bool get tools => raw.containsKey('tools');
  bool get toolsListChanged => asBool(_section('tools')?['listChanged']) ?? false;
  bool get prompts => raw.containsKey('prompts');
  bool get promptsListChanged => asBool(_section('prompts')?['listChanged']) ?? false;
  bool get resources => raw.containsKey('resources');
  bool get resourcesSubscribe => asBool(_section('resources')?['subscribe']) ?? false;
  bool get resourcesListChanged => asBool(_section('resources')?['listChanged']) ?? false;

  /// Deprecated in 2026-07-28 but still functional.
  bool get logging => raw.containsKey('logging');
  bool get completions => raw.containsKey('completions');

  /// `extensions` (M; some L servers carry it too).
  Map<String, JsonMap> get extensions => {
        for (final e in (asMap(raw['extensions']) ?? const <String, Object?>{}).entries)
          if (e.value is Map) e.key: (e.value! as Map).cast<String, Object?>(),
      };

  bool hasExtension(String id) => extensions.containsKey(id);

  /// MCP Apps negotiated on the server side (R03 §2).
  bool get supportsUi => hasExtension(McpExtensionIds.ui);

  /// The Tasks extension (R01 §8).
  bool get supportsTasks => hasExtension(McpExtensionIds.tasks);
}

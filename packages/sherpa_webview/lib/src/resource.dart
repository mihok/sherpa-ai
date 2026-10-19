/// The `ui://` resource a View is rendered from (R03 §4).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import 'policy/csp.dart';
import 'policy/limits.dart';

/// `text/html;profile=mcp-app`.
const String mcpAppMimeType = 'text/html;profile=mcp-app';

/// Why a resource cannot be rendered. The chat then shows the tool's
/// `content` blocks (servers MUST return meaningful content regardless).
final class McpAppResourceException implements Exception {
  const McpAppResourceException(this.message);

  final String message;

  @override
  String toString() => 'McpAppResourceException: $message';
}

/// Declared permissions (`_meta.ui.permissions`). Recorded for the consent
/// UI; none are granted in this version.
@immutable
final class McpAppPermissions {
  const McpAppPermissions({
    this.camera = false,
    this.microphone = false,
    this.geolocation = false,
    this.clipboardWrite = false,
  });

  factory McpAppPermissions.fromJson(Object? j) {
    if (j is! Map) return const McpAppPermissions();
    bool has(String k) => j[k] is Map;
    return McpAppPermissions(
      camera: has('camera'),
      microphone: has('microphone'),
      geolocation: has('geolocation'),
      clipboardWrite: has('clipboardWrite'),
    );
  }

  final bool camera;
  final bool microphone;
  final bool geolocation;
  final bool clipboardWrite;

  bool get any => camera || microphone || geolocation || clipboardWrite;
}

/// A validated UI resource: decoded HTML plus its security metadata.
@immutable
final class McpAppResource {
  const McpAppResource._({
    required this.uri,
    required this.html,
    required this.sha256,
    required this.declared,
    required this.permissions,
    this.prefersBorder,
    this.domain,
  });

  /// Validates one `resources/read` content item ([text] or base64 [blob])
  /// against the spec: `ui://` URI, `text/html;profile=mcp-app` mime type,
  /// UTF-8 HTML within [limits]. `_meta.ui` comes from the content item
  /// ([contentMeta], or the Python SDK's `meta`), falling back to the
  /// `resources/list` entry ([listingMeta]).
  ///
  /// Throws [McpAppResourceException].
  factory McpAppResource.fromContents({
    required String uri,
    required String? mimeType,
    String? text,
    String? blob,
    Map<String, Object?>? contentMeta,
    Map<String, Object?>? listingMeta,
    McpAppLimits limits = const McpAppLimits(),
  }) {
    if (!uri.startsWith('ui://')) throw McpAppResourceException('not a ui:// resource: $uri');
    if (!isMcpAppMimeType(mimeType)) throw McpAppResourceException('unsupported mime type: $mimeType');
    final List<int> bytes;
    if (text != null) {
      bytes = utf8.encode(text);
    } else if (blob != null) {
      try {
        bytes = base64.decode(blob.replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        throw const McpAppResourceException('blob is not valid base64');
      }
    } else {
      throw const McpAppResourceException('resource has neither text nor blob');
    }
    if (bytes.length > limits.maxHtmlBytes) {
      throw McpAppResourceException('resource is ${bytes.length} bytes (limit ${limits.maxHtmlBytes})');
    }
    final String html;
    try {
      // UTF-8, never Latin-1 (basic-host's atob() bug, R03 §4).
      html = text ?? utf8.decode(bytes);
    } on FormatException {
      throw const McpAppResourceException('blob is not UTF-8');
    }
    if (html.trim().isEmpty) throw const McpAppResourceException('resource HTML is empty');
    final ui = _ui(contentMeta) ?? _ui(listingMeta) ?? const <String, Object?>{};
    final csp = ui['csp'];
    return McpAppResource._(
      uri: uri,
      html: html,
      sha256: sha256Of(bytes),
      declared: DeclaredDomains.fromCsp(csp is Map ? csp.cast<String, Object?>() : null),
      permissions: McpAppPermissions.fromJson(ui['permissions']),
      prefersBorder: ui['prefersBorder'] is bool ? ui['prefersBorder']! as bool : null,
      domain: ui['domain'] is String ? ui['domain']! as String : null,
    );
  }

  static Map<String, Object?>? _ui(Map<String, Object?>? meta) {
    final ui = meta?['ui'];
    return ui is Map ? ui.cast<String, Object?>() : null;
  }

  static String sha256Of(List<int> bytes) => crypto.sha256.convert(bytes).toString();

  /// Accepts `text/html;profile=mcp-app` with optional spaces and any case.
  static bool isMcpAppMimeType(String? mime) {
    if (mime == null) return false;
    final parts = mime.toLowerCase().split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return parts.length == 2 && parts[0] == 'text/html' && parts[1] == 'profile=mcp-app';
  }

  final String uri;
  final String html;

  /// SHA-256 of the HTML bytes: consent is keyed by server + this hash
  /// (re-prompt when the UI or its CSP changes, R03 §11.8).
  final String sha256;

  /// Validated `connectDomains` / `resourceDomains` (not yet granted).
  final DeclaredDomains declared;
  final McpAppPermissions permissions;

  /// `_meta.ui.prefersBorder`; null lets the host decide.
  final bool? prefersBorder;

  /// `_meta.ui.domain`. Cannot be honoured: Views run at an opaque origin
  /// (fetches send `Origin: null`). Kept for diagnostics.
  final String? domain;
}

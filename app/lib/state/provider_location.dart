import 'dart:io' show InternetAddress;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart' show AddressKind, classify;
import 'package:sherpa_providers/sherpa_providers.dart';

/// Where prompts sent to [config] physically go. Drives every privacy badge
/// and the privacy dashboard, so it errs towards "leaves the device".
///
/// - loopback (127.0.0.1, ::1, localhost): a server running on this phone
///   (e.g. llama.cpp in Termux) → on device;
/// - private addresses, `.local`, or anything the user marked as "my own
///   network" → local network (still leaves the phone!);
/// - everything else → remote.
ExecutionLocation locationOf(ProviderConfig config) {
  final host = config.baseUrl.host.toLowerCase();
  final bare = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  final literal = InternetAddress.tryParse(bare);
  if (literal != null) {
    return switch (classify(literal)) {
      AddressKind.loopback => ExecutionLocation.onDevice,
      AddressKind.private || AddressKind.linkLocal => ExecutionLocation.localNetwork,
      _ => ExecutionLocation.remote,
    };
  }
  if (host == 'localhost' || host.endsWith('.localhost')) return ExecutionLocation.onDevice;
  if (host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa')) {
    return ExecutionLocation.localNetwork;
  }
  return config.allowLocalNetwork ? ExecutionLocation.localNetwork : ExecutionLocation.remote;
}

/// Host shown in "Leaves device → host" (port kept for LAN servers, where it
/// tells Ollama apart from LM Studio on the same machine).
String hostLabel(Uri uri) {
  final host = uri.host;
  final defaultPort = (uri.scheme == 'https' && uri.port == 443) || (uri.scheme == 'http' && uri.port == 80);
  return !uri.hasPort || defaultPort ? host : '$host:${uri.port}';
}

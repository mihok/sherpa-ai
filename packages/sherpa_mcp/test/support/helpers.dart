import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';

/// Loopback-only policy that never touches DNS.
const UrlPolicy loopbackPolicy = UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, resolver: _loopback);

Future<List<InternetAddress>> _loopback(String host) async => [InternetAddress.loopbackIPv4];

McpServerConfig serverConfig(
  Uri url, {
  McpTransportPreference transport = McpTransportPreference.auto,
  EraVerdict? verdict,
  String id = 'srv',
}) =>
    McpServerConfig(
      id: id,
      name: 'Test server',
      url: url,
      transport: transport,
      cachedVerdict: verdict,
      allowLocalNetwork: true,
    );

McpClientOptions options({
  http.Client? client,
  InputRequestHandler? handler,
  McpClientCapabilities capabilities = const McpClientCapabilities(),
  McpAuthHook? auth,
  McpTimeouts timeouts = const McpTimeouts(
    request: Duration(seconds: 5),
    probe: Duration(seconds: 5),
    inProcessProbe: Duration(milliseconds: 300),
    listenAck: Duration(seconds: 5),
    sseEndpoint: Duration(seconds: 3),
  ),
  McpLimits limits = const McpLimits(),
  EraVerdictCache? cache,
  McpLogLevel? logLevel,
}) =>
    McpClientOptions(
      httpClient: client ?? IOClient(),
      inputHandler: handler,
      capabilities: capabilities,
      authHook: auth,
      timeouts: timeouts,
      limits: limits,
      verdictCache: cache,
      urlPolicy: loopbackPolicy,
      logLevel: logLevel,
    );

/// Answers input requests from scripted callbacks and records them.
final class ScriptedHandler implements InputRequestHandler {
  ScriptedHandler({this.onElicit, this.onSample, this.onRoots});

  FutureOr<McpElicitResult> Function(McpElicitRequest r, McpInputContext c)? onElicit;
  FutureOr<McpSamplingResult> Function(McpSamplingRequest r, McpInputContext c)? onSample;
  FutureOr<List<McpRoot>> Function(McpInputContext c)? onRoots;
  final List<McpElicitRequest> elicitations = [];
  final List<McpSamplingRequest> samplings = [];
  final List<McpInputContext> contexts = [];
  int rootsCalls = 0;

  @override
  Future<McpElicitResult> elicit(McpElicitRequest request, McpInputContext context) async {
    elicitations.add(request);
    contexts.add(context);
    final f = onElicit;
    return f == null ? const McpElicitResult.decline() : await f(request, context);
  }

  @override
  Future<McpSamplingResult> createMessage(McpSamplingRequest request, McpInputContext context) async {
    samplings.add(request);
    contexts.add(context);
    final f = onSample;
    if (f == null) throw const InputRequestDeclined();
    return f(request, context);
  }

  @override
  Future<List<McpRoot>> listRoots(McpInputContext context) async {
    rootsCalls++;
    contexts.add(context);
    final f = onRoots;
    return f == null ? const [] : await f(context);
  }
}

/// Waits until [test] holds (polling), failing after [timeout].
Future<void> eventually(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!test()) {
    if (sw.elapsed > timeout) throw TimeoutException('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

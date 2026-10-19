import 'package:sherpa_mcp/sherpa_mcp.dart';

/// What a server asked for that Sherpa could not provide yet.
final class McpDeclinedInput {
  const McpDeclinedInput({required this.serverId, required this.serverName, required this.kind, this.originName});

  final String serverId;
  final String serverName;

  /// `form`, `url`, `sampling` or `roots`.
  final String kind;

  /// The tool, prompt or resource whose request asked.
  final String? originName;
}

/// A headless [InputRequestHandler] that politely declines every server →
/// client request: for runs without a UI (evals, background tools, tests).
/// The app uses `InteractiveInputHandler` (native forms, the URL-consent
/// sheet and sampling approval; `input/interactive_handler.dart`).
///
/// * Elicitation is answered `decline` (the spec's "the user said no"), so
///   the server decides what its tool returns; the router tells the model
///   the input was not given and not to retry.
/// * Sampling and roots are refused with a reason the server (and, through
///   the router, the model) can read. Sampling is off by default anyway
///   (PLAN §7 Q5) and roots are not declared.
final class DecliningInputHandler implements InputRequestHandler {
  const DecliningInputHandler({this.onDeclined});

  /// Told about every decline (e.g. to note it in the server's console).
  final void Function(McpDeclinedInput input)? onDeclined;

  static const String samplingReason =
      'Sherpa cannot ask the user right now whether this tool server may use the model, so this request was declined.';
  static const String rootsReason = 'Sherpa does not share folders with tool servers.';

  void _note(McpInputContext context, String kind) => onDeclined?.call(McpDeclinedInput(
        serverId: context.serverId,
        serverName: context.serverName,
        kind: kind,
        originName: context.originName,
      ));

  @override
  Future<McpElicitResult> elicit(McpElicitRequest request, McpInputContext context) async {
    _note(context, request.mode.name);
    return const McpElicitResult.decline();
  }

  @override
  Future<McpSamplingResult> createMessage(McpSamplingRequest request, McpInputContext context) async {
    _note(context, 'sampling');
    throw const InputRequestDeclined(samplingReason);
  }

  @override
  Future<List<McpRoot>> listRoots(McpInputContext context) async {
    _note(context, 'roots');
    throw const InputRequestDeclined(rootsReason);
  }
}

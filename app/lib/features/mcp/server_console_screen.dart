import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../design/tokens.dart';
import '../../design/widgets/state_views.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// The redacted log ring of one server (`McpServerManager.logs`): what the
/// client did (connects, probes, losses) and what the server logged. Server
/// lines are untrusted text and never reach the model.
class ServerConsoleScreen extends ConsumerWidget {
  const ServerConsoleScreen({super.key, required this.serverId});

  final String serverId;

  static String format(McpLogEntry e) {
    final at = e.at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)} ${e.source == McpLogSource.server ? 'server' : 'sherpa'} '
        '${e.level}: ${e.message}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(mcpRevisionProvider);
    final rt = ref.watch(mcpRuntimeProvider);
    final t = SherpaTokens.of(context);
    final config = rt.server(serverId);
    final logs = config == null ? const <McpLogEntry>[] : rt.manager.logs(serverId);
    final declined = rt.declinedInputs(serverId);
    final text = logs.map(format).join('\n');
    return Scaffold(
      appBar: AppBar(
        title: Semantics(headingLevel: 1, child: Text(config == null ? 'Debug console' : '${config.name} console')),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: logs.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
                  },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: logs.isEmpty
                ? null
                : () {
                    rt.manager.clearLogs(serverId);
                    ref.invalidate(mcpRevisionProvider);
                  },
          ),
        ],
      ),
      body: config == null
          ? const StateView(icon: Icons.extension_off_outlined, title: 'Server not found')
          : ListView(
              padding: EdgeInsets.all(t.space.lg),
              children: [
                const NoteBox(
                  text: 'Tokens, keys and passwords are removed from these lines. Lines marked "server" come from '
                      'the server itself and may be wrong or misleading.',
                ),
                if (declined.isNotEmpty) ...[
                  SizedBox(height: t.space.md),
                  NoteBox(
                    tone: NoteTone.warning,
                    icon: Icons.block_rounded,
                    text: 'The server asked for input Sherpa cannot give yet (forms, web pages, its own model use) '
                        '${declined.length} time${declined.length == 1 ? '' : 's'}; each was declined.',
                  ),
                ],
                SizedBox(height: t.space.md),
                if (logs.isEmpty) const Text('Nothing logged yet.') else MonoBlock(text, semanticsLabel: 'Log lines'),
              ],
            ),
    );
  }
}

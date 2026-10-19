import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Remembered "allow" answers: which tool, on which server, for how long
/// (always, or one chat) and until when. Each can be revoked; a revoked
/// tool asks again next time.
class ApprovalsScreen extends ConsumerWidget {
  const ApprovalsScreen({super.key});

  static String scopeLabel(ApprovalGrant g) => switch (g.scope) {
        ApprovalScope.always => 'Always allowed',
        ApprovalScope.session => 'Allowed in one chat',
        ApprovalScope.once => 'Allowed once',
      };

  Future<void> _revokeAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: motionStyleOf(context),
      builder: (context) => AlertDialog(
        title: const Heading(child: Text('Revoke all approvals?')),
        content: const Text('Every tool asks again before it runs.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Revoke all')),
        ],
      ),
    );
    if (ok ?? false) ref.read(mcpRuntimeProvider).policy.revokeWhere((_) => true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grants = ref.watch(mcpGrantsProvider);
    final router = ref.watch(toolRouterProvider);
    final mcp = ref.watch(mcpRuntimeProvider).router;
    final now = ref.watch(clockProvider).now();
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    if (grants.isEmpty) {
      return const SettingsPage(
        title: 'Remembered approvals',
        children: [
          SizedBox(height: 48),
          StateView(
            icon: Icons.verified_user_outlined,
            title: 'No remembered approvals',
            message: 'When a tool asks before running, you can allow it for the chat or always. Those answers show up here.',
          ),
        ],
      );
    }
    return SettingsPage(
      title: 'Remembered approvals',
      actions: [
        TextButton(onPressed: () => _revokeAll(context, ref), child: const Text('Revoke all')),
      ],
      children: [
        SettingsPadding(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: t.space.md),
            child: Text(
              'These tools may run without asking. An approval covers the exact version of the tool you saw: if the '
              'server changes it, Sherpa asks again.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        SectionHeader(
          'Allowed without asking',
          count: grants.length == 1 ? '1 tool' : '${grants.length} tools',
        ),
        for (final g in grants)
          _GrantTile(
            grant: g,
            tool: router.lookup(g.toolName),
            label: mcp.entryFor(g.toolName)?.tool.displayName,
            now: now,
          ),
      ],
    );
  }
}

class _GrantTile extends ConsumerWidget {
  const _GrantTile({required this.grant, required this.tool, required this.now, this.label});

  final ApprovalGrant grant;
  final ToolDefinition? tool;

  /// The MCP tool's own title or name (the definition's name is namespaced).
  final String? label;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = label ?? tool?.displayName ?? grant.toolName;
    final i = grant.toolName.indexOf('__');
    final server = tool?.source.serverName ?? (i > 0 ? grant.toolName.substring(0, i) : null);
    final lines = [
      if (server != null) 'On $server',
      ApprovalsScreen.scopeLabel(grant),
      describeExpiry(grant.expiresAt, now),
      if (tool == null) 'Tool not loaded right now',
    ];
    return ListTile(
      leading: Icon(grant.scope == ApprovalScope.always ? Icons.all_inclusive_rounded : Icons.chat_bubble_outline_rounded),
      title: Text(name),
      subtitle: Text(lines.join(' · ')),
      trailing: IconButton(
        tooltip: 'Revoke approval for $name',
        icon: const Icon(Icons.remove_circle_outline_rounded),
        onPressed: () {
          ref.read(hapticsProvider).selection();
          ref.read(mcpRuntimeProvider).policy.revokeGrant(grant);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name will ask again')));
        },
      ),
    );
  }
}

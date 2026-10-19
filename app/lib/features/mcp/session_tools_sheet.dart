import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../state/ui_preferences.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Which tool servers and tools one chat may use.
///
/// Switches here apply to this chat only (the global ones live in
/// Tools & servers). The tool list is part of the prompt, so changes take
/// effect from the next message, never in the middle of a reply.
///
/// Open with [SessionToolsSheet.show] from the chat.
class SessionToolsSheet extends ConsumerWidget {
  const SessionToolsSheet({super.key, required this.sessionId, this.onManage});

  final String sessionId;

  /// "Manage servers": the chat navigates to Tools & servers.
  final VoidCallback? onManage;

  static Future<void> show(BuildContext context, {required String sessionId, VoidCallback? onManage}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => SessionToolsSheet(sessionId: sessionId, onManage: onManage),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final groups = ref.watch(sessionToolsProvider(sessionId));
    final switches = ref.watch(sessionToolSwitchesProvider(sessionId));
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.only(bottom: t.space.xl),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.xs),
            child: Semantics(headingLevel: 2, child: Text('Tools in this chat', style: theme.textTheme.titleLarge)),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.xl),
            child: Text('Changes apply from your next message.', style: muted),
          ),
          if (groups.isEmpty)
            Padding(
              padding: EdgeInsets.all(t.space.xl),
              child: Text('No tool servers are turned on. Add or turn one on in Tools & servers.', style: muted),
            ),
          for (final g in groups) ...[
            SwitchListTile(
              title: Text(g.server.name, style: theme.textTheme.titleMedium),
              subtitle: Wrap(
                spacing: t.space.xs,
                runSpacing: t.space.xs,
                children: [
                  McpStatusPill(status: g.server.status),
                  if (g.server.builtIn) const BuiltInPill(),
                  if (g.server.pendingReviews > 0)
                    McpPill(
                      label: '${g.server.pendingReviews} waiting for review',
                      icon: Icons.rate_review_outlined,
                      color: t.semantic.warning,
                    ),
                ],
              ),
              value: g.enabled,
              onChanged: (v) {
                ref.read(hapticsProvider).selection();
                unawaited(switches.setServer(g.server.id, v));
              },
            ),
            if (g.enabled)
              for (final tool in g.tools)
                Padding(
                  padding: EdgeInsetsDirectional.only(start: t.space.xl),
                  child: SwitchListTile(
                    dense: true,
                    title: Text(tool.label),
                    subtitle: tool.globallyEnabled ? null : const Text('Off in settings'),
                    value: tool.enabled,
                    onChanged: (v) {
                      ref.read(hapticsProvider).selection();
                      unawaited(switches.setTool(tool.name, v));
                    },
                  ),
                ),
          ],
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.md),
            child: Wrap(
              spacing: t.space.sm,
              runSpacing: t.space.sm,
              children: [
                OutlinedButton(
                  onPressed: () => unawaited(switches.reset()),
                  child: const Text('Use the settings defaults'),
                ),
                if (onManage != null)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onManage!();
                    },
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Manage servers'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

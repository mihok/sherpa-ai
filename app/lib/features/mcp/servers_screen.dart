import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/section_header.dart';
import '../../routing/routes.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'consent_sheet.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Settings › Tools & servers: built-in and added MCP servers with their
/// health, the tools waiting for review, and remembered approvals.
class ToolServersScreen extends ConsumerWidget {
  const ToolServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final servers = ref.watch(mcpServersProvider);
    final pending = ref.watch(mcpPendingReviewsProvider);
    final grants = ref.watch(mcpGrantsProvider);
    final builtIn = [for (final s in servers) if (s.builtIn) s];
    final added = [for (final s in servers) if (!s.builtIn) s];
    return SettingsPage(
      title: 'Tools & servers',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.addServer),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add a server'),
      ),
      children: [
        SettingsPadding(
          child: Padding(
            padding: EdgeInsets.only(top: t.space.md),
            child: Text(
              'Tool servers (MCP) give the assistant abilities such as searching your notes or using an online '
              'service. Sherpa asks before a tool changes anything, unless you allowed it.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        if (pending.isNotEmpty) ...[
          SizedBox(height: t.space.md),
          SettingsPadding(
            child: Material(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(t.radius.md),
              child: ListTile(
                leading: Icon(Icons.rate_review_outlined, color: theme.colorScheme.onTertiaryContainer),
                title: Text(
                  pending.length == 1 ? '1 tool needs your review' : '${pending.length} tools need your review',
                  style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
                ),
                subtitle: Text(
                  'New or changed tools stay blocked until you look at them.',
                  style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
                ),
                trailing: Icon(Icons.chevron_right, color: theme.colorScheme.onTertiaryContainer),
                onTap: () {
                  final (r, _) = pending.first;
                  context.go(Routes.toolReview(r.key.serverId, r.key.toolName));
                },
              ),
            ),
          ),
        ],
        const SectionHeader('Built in'),
        for (final s in builtIn) _ServerTile(view: s),
        const SectionHeader('Your servers'),
        if (added.isEmpty)
          SettingsPadding(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space.md),
              child: Text(
                'No servers added yet. Add one by its address, from the MCP Registry, or by scanning a code.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        for (final s in added) _ServerTile(view: s),
        const SectionHeader('Approvals'),
        ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('Remembered approvals'),
          subtitle: Text(switch (grants.length) {
            0 => 'None: Sherpa asks every time',
            1 => '1 tool may run without asking',
            final n => '$n tools may run without asking',
          }),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(Routes.toolApprovals),
        ),
      ],
    );
  }
}

class _ServerTile extends ConsumerWidget {
  const _ServerTile({required this.view});

  final McpServerView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final rt = ref.read(mcpRuntimeProvider);
    final problem = view.problem;
    final needsAuth = view.status == McpServerDisplayStatus.needsAuth && view.config.enabled;
    final toolsLine = switch (view.tools.length) {
      0 => null,
      1 => '1 tool',
      final n => '$n tools',
    };
    return ListTile(
        isThreeLine: problem != null || needsAuth,
        title: Text(view.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: t.space.xxs),
            Wrap(
              spacing: t.space.xs,
              runSpacing: t.space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                McpStatusPill(status: view.status),
                if (view.builtIn) const BuiltInPill(),
                if (view.pendingReviews > 0)
                  McpPill(
                    label: '${view.pendingReviews} to review',
                    icon: Icons.rate_review_outlined,
                    color: t.semantic.warning,
                  ),
              ],
            ),
            SizedBox(height: t.space.xxs),
            Text([view.hostLabel, ?toolsLine].join(' · ')),
            if (problem != null)
              Padding(
                padding: EdgeInsets.only(top: t.space.xxs),
                child: Text(problem, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            if (needsAuth)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => startMcpSignIn(context, ref, view.id),
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('Sign in'),
                ),
              ),
          ],
        ),
        trailing: Semantics(
          label: 'Use ${view.name}',
          child: Switch(
            value: view.config.enabled,
            onChanged: (v) {
              ref.read(hapticsProvider).selection();
              unawaited(rt.setEnabled(view.id, v));
            },
          ),
        ),
        onTap: () => context.go(Routes.toolServer(view.id)),
    );
  }
}

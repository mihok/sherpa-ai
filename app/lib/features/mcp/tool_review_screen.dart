import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Reviews one tool: the full definition of a new tool, the readable diff
/// of a changed one (`ToolReview.describe()`), and the hygiene findings.
/// Approving pins the CURRENT definition; "Keep blocked" leaves it
/// quarantined (neither offered to the model nor runnable).
class ToolReviewScreen extends ConsumerWidget {
  const ToolReviewScreen({super.key, required this.serverId, required this.toolName});

  final String serverId;
  final String toolName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = McpToolKey(serverId, toolName);
    final review = ref.watch(mcpToolReviewProvider(key));
    final server = ref.watch(mcpServerProvider(serverId));
    if (review == null || server == null) {
      return Scaffold(
        appBar: AppBar(),
        body: StateView(
          icon: Icons.build_circle_outlined,
          title: 'Tool not found',
          message: 'The server may not list it any more.',
          primaryAction: FilledButton(onPressed: () => context.go(Routes.tools), child: const Text('Back to servers')),
        ),
      );
    }
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final rt = ref.read(mcpRuntimeProvider);
    final entry = rt.router.entryForKey(key);
    final changed = review.status == ToolReviewStatus.quarantinedChanged;
    final diff = review.diff;
    Future<void> approve() async {
      final ok = await rt.approveTool(key);
      ref.read(hapticsProvider).success();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Approved $toolName' : "Couldn't approve $toolName")));
      final next = ref.read(mcpPendingReviewsProvider).where((p) => p.$1.key != key).firstOrNull;
      context.go(next == null ? Routes.toolServer(serverId) : Routes.toolReview(next.$1.key.serverId, next.$1.key.toolName));
    }

    return SettingsPage(
      title: changed ? 'Review a changed tool' : (review.quarantined ? 'Review a new tool' : 'Tool details'),
      bottom: review.quarantined
          ? Wrap(
              alignment: WrapAlignment.end,
              spacing: t.space.sm,
              runSpacing: t.space.sm,
              children: [
                TextButton(onPressed: () => context.go(Routes.toolServer(serverId)), child: const Text('Keep blocked')),
                FilledButton.icon(
                  onPressed: () => unawaited(approve()),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(changed ? 'Approve the change' : 'Approve this tool'),
                ),
              ],
            )
          : null,
      children: [
        SettingsPadding(
          child: Padding(
            padding: EdgeInsets.only(top: t.space.md),
            child: HeadingGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Heading(
                    level: 2,
                    child: Text(entry?.tool.displayName ?? toolName, style: theme.textTheme.titleLarge),
                  ),
                  Text('${entry?.modelName ?? toolName} · ${server.name}', style: muted),
                  SizedBox(height: t.space.md),
                  if (changed)
                    const NoteBox(
                      title: 'This tool changed since you approved it',
                      icon: Icons.difference_outlined,
                      tone: NoteTone.danger,
                      text: 'A server can change what a tool says or does after you approved it (a "rug pull"). '
                          'It is blocked until you check the change. Earlier "always allow" answers do not cover the new version.',
                    )
                  else if (review.quarantined)
                    NoteBox(
                      title: 'New tool',
                      icon: Icons.rate_review_outlined,
                      tone: NoteTone.warning,
                      text: server.config.trusted
                          ? 'Sherpa found a problem in its description, so it waits for you even though you trust the server.'
                          : "You haven't marked ${server.name} as trusted, so each new tool waits for you. Read what it says "
                              'it does before allowing it.',
                    ),
                  if (diff != null && diff.descriptionChanged) ...[
                    SizedBox(height: t.space.sm),
                    const NoteBox(
                      icon: Icons.find_in_page_outlined,
                      text: 'Its description changed. Instructions hidden in a description are a common way to '
                          'trick an assistant, so read the added text closely.',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        SectionHeader(changed ? 'What changed' : 'Definition'),
        SettingsPadding(child: MonoBlock(review.describe(serverName: server.name), semanticsLabel: 'Tool definition')),
        if (review.findings.isNotEmpty) ...[
          const SectionHeader('Warnings'),
          for (final f in review.findings)
            ListTile(
              leading: Icon(
                f.isCritical ? Icons.gpp_bad_outlined : Icons.warning_amber_rounded,
                color: f.isCritical ? t.semantic.danger : t.semantic.warning,
              ),
              title: Text('${f.isCritical ? 'Critical' : 'Warning'}: ${f.message}'),
              subtitle: Text([f.location, if (f.excerpt != null) f.excerpt!].join(' — '), maxLines: 4, overflow: TextOverflow.ellipsis),
            ),
          SettingsPadding(
            child: Text('A flagged tool asks before every call, even after you approve it.', style: muted),
          ),
        ],
        if (entry != null) ...[
          const SectionHeader('What it says about itself'),
          SettingsPadding(child: DeclaredHints(annotations: entry.tool.annotations, trusted: entry.annotationsTrusted)),
        ],
      ],
    );
  }
}

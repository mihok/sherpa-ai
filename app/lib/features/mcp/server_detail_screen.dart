import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/mcp/server_probe.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'consent_sheet.dart';
import 'server_host_sections.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// One server: health, trust, its tools (declared hints, hygiene, switches),
/// MCP Apps (on/off, network consents) and use of the user's model
/// (sampling), resources and prompts, the debug console, and reconnect /
/// sign out / remove.
class ServerDetailScreen extends ConsumerWidget {
  const ServerDetailScreen({super.key, required this.serverId});

  final String serverId;

  Future<void> _remove(BuildContext context, WidgetRef ref, McpServerView v) async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: motionStyleOf(context),
      builder: (context) => AlertDialog(
        title: Heading(child: Text('Remove ${v.name}?')),
        content: const Text('Its tools disappear from your chats, its sign-in is deleted from this phone, and the '
            'approvals you gave its tools are forgotten.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (!(ok ?? false) || !context.mounted) return;
    await ref.read(mcpRuntimeProvider).removeServer(v.id);
    ref.read(hapticsProvider).success();
    if (context.mounted) context.go(Routes.tools);
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref, McpServerView v) async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: motionStyleOf(context),
      builder: (context) => AlertDialog(
        title: Heading(child: Text('Sign out of ${v.name}?')),
        content: const Text('The sign-in token is revoked and deleted from this phone. You can sign in again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign out')),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    await ref.read(mcpRuntimeProvider).signOut(v.id);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Signed out of ${v.name}')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(mcpServerProvider(serverId));
    if (v == null) {
      return Scaffold(
        appBar: AppBar(),
        body: StateView(
          icon: Icons.extension_off_outlined,
          title: 'Server not found',
          message: 'It may have been removed.',
          primaryAction: FilledButton(onPressed: () => context.go(Routes.tools), child: const Text('Back to servers')),
        ),
      );
    }
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final rt = ref.read(mcpRuntimeProvider);
    final h = v.health;
    final era = describeEra(h.era, h.protocolVersion, rt.manager.connectedOrNull(v.id)?.transportKind);
    final problem = v.problem;
    final hasCreds = !v.builtIn && (ref.watch(mcpHasCredentialsProvider(v.id)).value ?? false);
    final findings = rt.router.instructionFindings(v.id);
    final tools = [...v.tools]..sort((a, b) => (a.quarantined ? 0 : 1).compareTo(b.quarantined ? 0 : 1));
    return SettingsPage(
      title: v.name,
      children: [
        SettingsPadding(
          child: Padding(
            padding: EdgeInsets.only(top: t.space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Announced when the connection state changes (connecting,
                // connected, sign-in needed, offline).
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Wrap(
                    spacing: t.space.xs,
                    runSpacing: t.space.xs,
                    children: [McpStatusPill(status: v.status), if (v.builtIn) const BuiltInPill()],
                  ),
                ),
                SizedBox(height: t.space.sm),
                Text(v.builtIn ? 'Runs inside Sherpa on this phone.' : v.config.url.toString(), style: muted),
                if (era != null) Text(era, style: muted),
                if (h.latency != null && v.status == McpServerDisplayStatus.connected)
                  Text('Answered in ${h.latency!.inMilliseconds} ms', style: muted),
                if (h.serverName != null && !v.builtIn) Text('Calls itself "${h.serverName}"', style: muted),
                if (v.meta?.registryName != null) Text('Registry: ${v.meta!.registryName}', style: muted),
                if (problem != null) ...[
                  SizedBox(height: t.space.sm),
                  NoteBox(text: problem, icon: Icons.error_outline_rounded, tone: NoteTone.danger),
                ],
                SizedBox(height: t.space.md),
                Wrap(
                  spacing: t.space.sm,
                  runSpacing: t.space.sm,
                  children: [
                    if (v.status == McpServerDisplayStatus.needsAuth && v.config.enabled)
                      FilledButton.icon(
                        onPressed: () => startMcpSignIn(context, ref, v.id),
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Sign in'),
                      ),
                    OutlinedButton.icon(
                      onPressed: v.config.enabled ? () => unawaited(rt.reconnect(v.id)) : null,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Reconnect'),
                    ),
                    if (hasCreds)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(_signOut(context, ref, v)),
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Sign out'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SectionHeader('Settings'),
        SwitchListTile(
          secondary: const Icon(Icons.power_settings_new_rounded),
          title: const Text('Use this server'),
          subtitle: const Text('Off: its tools are not offered in any chat.'),
          value: v.config.enabled,
          onChanged: (on) {
            ref.read(hapticsProvider).selection();
            unawaited(rt.setEnabled(v.id, on));
          },
        ),
        if (!v.builtIn)
          SwitchListTile(
            secondary: const Icon(Icons.handshake_outlined),
            title: const Text('Trust this server'),
            subtitle: const Text('Sherpa then relies on what the server says about its tools: tools it marks read-only '
                'may run without asking, and tools it adds later are approved without review. Changed tools are '
                'still blocked for review. Only trust servers you run or know well.'),
            isThreeLine: true,
            value: v.config.trusted,
            onChanged: (on) {
              ref.read(hapticsProvider).selection();
              rt.setTrusted(v.id, on);
            },
          )
        else
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: const Text('Trusted'),
            subtitle: const Text('Built-in servers ship with Sherpa, so what they say about their tools is honest.'),
          ),
        SectionHeader(
          'Tools',
          count: tools.isEmpty ? null : (tools.length == 1 ? '1 tool' : '${tools.length} tools'),
          trailing: v.pendingReviews > 1
              ? TextButton(
                  onPressed: () async {
                    final n = await rt.approveAll(v.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approved $n tools')));
                    }
                  },
                  child: const Text('Approve all'),
                )
              : null,
        ),
        if (tools.isEmpty)
          SettingsPadding(
            child: Text(
              v.config.enabled
                  ? (v.status == McpServerDisplayStatus.connected ? 'This server offers no tools.' : 'Tools appear once Sherpa connects.')
                  : 'Turn the server on to see its tools.',
              style: muted,
            ),
          ),
        for (final e in tools) _ToolTile(entry: e),
        if (findings.isNotEmpty) ...[
          const SectionHeader("Warnings about the server's instructions"),
          for (final f in findings)
            ListTile(
              leading: Icon(Icons.warning_amber_rounded, color: t.semantic.warning),
              title: Text(f.message),
              subtitle: f.excerpt == null ? null : Text(f.excerpt!, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
        ],
        if (!v.builtIn) ...[
          McpAppsSection(serverId: v.id),
          McpSamplingSection(serverId: v.id),
        ],
        if (v.config.enabled) ...[
          const SectionHeader('Resources and prompts'),
          _LazyList(
            title: 'Resources',
            icon: Icons.description_outlined,
            load: () => rt.resourcesOf(v.id),
            itemBuilder: (r) => ListTile(
              dense: true,
              title: Text(r.title ?? (r.name.isEmpty ? r.uri : r.name), maxLines: scaledMaxLines(context), overflow: TextOverflow.ellipsis),
              subtitle: Text(r.uri, maxLines: scaledMaxLines(context), overflow: TextOverflow.ellipsis),
            ),
          ),
          _LazyList(
            title: 'Prompts',
            icon: Icons.chat_bubble_outline_rounded,
            load: () => rt.promptsOf(v.id),
            itemBuilder: (p) => ListTile(
              dense: true,
              title: Text(p.displayName),
              subtitle: p.description == null ? null : Text(p.description!, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        const SectionHeader('Troubleshooting'),
        ListTile(
          leading: const Icon(Icons.terminal_rounded),
          title: const Text('Debug console'),
          subtitle: const Text('What Sherpa and the server did, with secrets removed'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(Routes.toolServerConsole(v.id)),
        ),
        if (!v.builtIn)
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
            title: Text('Remove server', style: TextStyle(color: theme.colorScheme.error)),
            onTap: () => unawaited(_remove(context, ref, v)),
          ),
      ],
    );
  }
}

class _ToolTile extends ConsumerWidget {
  const _ToolTile({required this.entry});

  final McpCatalogEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final rt = ref.read(mcpRuntimeProvider);
    final enabled = rt.isToolEnabled(entry.modelName);
    final desc = entry.tool.description;
    return ListTile(
      isThreeLine: true,
      title: Text(entry.tool.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.modelName, style: theme.textTheme.bodySmall),
          if (desc != null && desc.isNotEmpty) Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis),
          SizedBox(height: t.space.xs),
          if (entry.quarantined || entry.flagged) ...[
            ToolReviewPill(entry: entry),
            SizedBox(height: t.space.xs),
          ],
          DeclaredHints(annotations: entry.tool.annotations, trusted: entry.annotationsTrusted),
        ],
      ),
      trailing: entry.quarantined
          ? const Icon(Icons.chevron_right)
          : Semantics(
              label: 'Use ${entry.tool.displayName}',
              child: Switch(
                value: enabled,
                onChanged: (on) {
                  ref.read(hapticsProvider).selection();
                  unawaited(rt.setToolEnabled(entry.modelName, on));
                },
              ),
            ),
      onTap: () => context.go(Routes.toolReview(entry.key.serverId, entry.key.toolName)),
    );
  }
}

class _LazyList<T> extends StatefulWidget {
  const _LazyList({required this.title, required this.icon, required this.load, required this.itemBuilder});

  final String title;
  final IconData icon;

  /// Runs when the list is opened (listing connects the server).
  final Future<List<T>> Function() load;
  final Widget Function(T item) itemBuilder;

  @override
  State<_LazyList<T>> createState() => _LazyListState<T>();
}

class _LazyListState<T> extends State<_LazyList<T>> {
  Future<List<T>>? _items;

  /// How many there are, once loaded: shown (and spoken) on the row.
  String? _count;

  /// "None", "1 prompt", "3 prompts".
  String _describe(int n) {
    final plural = widget.title.toLowerCase();
    final one = plural.endsWith('s') ? plural.substring(0, plural.length - 1) : plural;
    return n == 0 ? 'None' : (n == 1 ? '1 $one' : '$n $plural');
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final open = _items != null;
    return Column(
      children: [
        Semantics(
          container: true,
          expanded: open,
          child: ListTile(
            leading: Icon(widget.icon),
            title: Text(widget.title),
            subtitle: _count == null ? null : Text(_count!),
            trailing: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            onTap: () {
              final next = open ? null : widget.load();
              setState(() {
                _items = next;
                _count = null;
              });
              next?.then((list) {
                if (mounted && identical(_items, next)) setState(() => _count = _describe(list.length));
              }).ignore();
            },
          ),
        ),
        if (open)
          FutureBuilder<List<T>>(
            future: _items,
            builder: (context, snap) {
              if (snap.hasError) return SettingsPadding(child: Text(describeConnectError(snap.error!), style: muted));
              final list = snap.data;
              if (list == null) {
                return Padding(
                  padding: EdgeInsets.all(t.space.md),
                  child: LinearProgressIndicator(semanticsLabel: 'Loading ${widget.title.toLowerCase()}'),
                );
              }
              if (list.isEmpty) return SettingsPadding(child: Text('None.', style: muted));
              return Column(children: [for (final i in list) widget.itemBuilder(i)]);
            },
          ),
      ],
    );
  }
}

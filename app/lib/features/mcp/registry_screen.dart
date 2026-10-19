import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../services/mcp/registry_client.dart';
import '../../state/connectivity.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Search the official MCP Registry for servers a phone can use (remote
/// streamable-http or SSE endpoints). Picking one opens the add screen
/// filled in; nothing is added from here.
class RegistrySearchScreen extends ConsumerStatefulWidget {
  const RegistrySearchScreen({super.key});

  @override
  ConsumerState<RegistrySearchScreen> createState() => _RegistrySearchScreenState();
}

class _RegistrySearchScreenState extends ConsumerState<RegistrySearchScreen> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<McpRegistryEntry> _entries = const [];
  String? _cursor;
  String _searched = '';
  bool _loading = false;
  McpRegistryException? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_search(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(_search(q)));
  }

  Future<void> _search(String q, {bool more = false}) async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _searched = q.trim();
    });
    try {
      final page = await ref.read(mcpRegistryClientProvider).search(_searched, cursor: more ? _cursor : null);
      if (!mounted || gen != _generation) return;
      setState(() {
        _entries = more ? [..._entries, ...page.entries] : page.entries;
        _cursor = page.nextCursor;
      });
    } on McpRegistryException catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  void _pick(McpRegistryEntry e) {
    final remote = e.preferredRemote;
    if (remote == null) return;
    context.go(Routes.addServerWith(
      url: remote.url,
      name: e.displayName,
      source: 'registry',
      registryName: e.name,
      description: e.description,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final offline = ref.watch(networkStatusProvider).value == NetworkStatus.offline;
    final usable = [for (final e in _entries) if (e.preferredRemote != null) e];
    final other = [for (final e in _entries) if (e.preferredRemote == null) e];
    Widget body;
    if (_error != null && _entries.isEmpty) {
      body = StateView(
        icon: _error!.failure == McpRegistryFailure.offline ? Icons.cloud_off_outlined : Icons.error_outline_rounded,
        title: _error!.failure == McpRegistryFailure.offline ? "Can't reach the registry" : 'The registry had a problem',
        message: _error!.message,
        tone: StateTone.warning,
        liveRegion: true,
        primaryAction: FilledButton(onPressed: () => unawaited(_search(_searched)), child: const Text('Try again')),
      );
    } else if (_entries.isEmpty && _loading) {
      body = const LoadingState(label: 'Searching the registry…');
    } else if (_entries.isEmpty) {
      body = StateView(
        icon: Icons.search_off_rounded,
        title: 'No servers found',
        message: _searched.isEmpty ? 'The registry returned nothing.' : 'Nothing matches "$_searched". Try another name.',
      );
    } else {
      final n = _entries.length;
      body = ListView(
        padding: EdgeInsets.only(bottom: t.space.xxxl),
        children: [
          // How many came back, said once per search (not per keystroke:
          // searches are debounced).
          Padding(
            padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xs, t.space.lg, t.space.xs),
            child: Semantics(
              liveRegion: true,
              child: Text(
                '${n == 1 ? '1 server' : '$n servers'}${_searched.isEmpty ? '' : ' for "$_searched"'}'
                '${_cursor == null ? '' : ', more available'}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          for (final e in usable) _EntryTile(entry: e, onTap: () => _pick(e)),
          if (other.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xl, t.space.lg, t.space.sm),
              child: Heading(
                level: 2,
                value: other.length == 1 ? '1 server' : '${other.length} servers',
                child: Text('Not usable from a phone yet', style: theme.textTheme.titleSmall),
              ),
            ),
            for (final e in other) _EntryTile(entry: e),
          ],
          if (_cursor != null)
            Padding(
              padding: EdgeInsets.all(t.space.lg),
              child: Center(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => unawaited(_search(_searched, more: true)),
                  child: Text(_loading ? 'Loading…' : 'Show more'),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.all(t.space.lg),
              child: NoteBox(text: _error!.message, tone: NoteTone.warning),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Heading(level: 1, child: const Text('MCP Registry'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.layout.maxContentWidth),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(t.space.lg, t.space.sm, t.space.lg, t.space.sm),
                child: TextField(
                  controller: _query,
                  onChanged: _onChanged,
                  onSubmitted: (q) => unawaited(_search(q)),
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Search servers',
                    hintText: 'e.g. github, notion, weather',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              if (offline)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.space.lg),
                  child: const NoteBox(text: 'You are offline. Results may not load.', icon: Icons.cloud_off_outlined),
                ),
              if (_loading && _entries.isNotEmpty) const LinearProgressIndicator(semanticsLabel: 'Searching the registry'),
              Expanded(child: body),
              SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.all(t.space.sm),
                  child: Text(
                    'From registry.modelcontextprotocol.io. Listings are written by their publishers and not reviewed.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, this.onTap});

  final McpRegistryEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final remote = entry.preferredRemote;
    final reason = entry.unsupportedReason;
    final host = remote == null ? null : Uri.tryParse(remote.url)?.host;
    return ListTile(
      enabled: onTap != null,
      isThreeLine: true,
      title: Text(entry.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.description, maxLines: 3, overflow: TextOverflow.ellipsis),
          SizedBox(height: t.space.xxs),
          Text(
            [entry.name, ?host, if (remote != null && !remote.isStreamableHttp) 'SSE'].join(' · '),
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (reason != null)
            Padding(
              padding: EdgeInsets.only(top: t.space.xxs),
              child: Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
      trailing: onTap == null ? null : const Icon(Icons.add_circle_outline_rounded),
      onTap: onTap,
    );
  }
}

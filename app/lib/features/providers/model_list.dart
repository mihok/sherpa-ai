import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/tokens.dart';
import '../../design/typography.dart';

/// Pick one model from a provider's list. Adds a filter field once the list
/// is long enough to need one (OpenRouter serves hundreds).
class ModelChoiceList extends StatefulWidget {
  const ModelChoiceList({
    super.key,
    required this.models,
    required this.selectedId,
    required this.onSelected,
    this.shrinkWrap = false,
  });

  final List<ModelDescriptor> models;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  /// Render as a plain column inside another scroll view.
  final bool shrinkWrap;

  static const int filterThreshold = 8;

  @override
  State<ModelChoiceList> createState() => _ModelChoiceListState();
}

class _ModelChoiceListState extends State<ModelChoiceList> {
  String _filter = '';

  List<ModelDescriptor> get _visible {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return widget.models;
    return [
      for (final m in widget.models)
        if (m.id.toLowerCase().contains(q) || m.displayName.toLowerCase().contains(q)) m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final visible = _visible;
    final tiles = [
      for (final m in visible)
        RadioListTile<String>(
          value: m.id,
          title: Text(m.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: _subtitle(m, theme),
          contentPadding: EdgeInsets.symmetric(horizontal: t.space.sm),
        ),
    ];
    final filter = widget.models.length >= ModelChoiceList.filterThreshold
        ? Padding(
            padding: EdgeInsets.only(bottom: t.space.sm),
            child: TextField(
              onChanged: (v) => setState(() => _filter = v),
              autocorrect: false,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter models'),
            ),
          )
        : null;
    final empty = visible.isEmpty
        ? Padding(
            padding: EdgeInsets.all(t.space.lg),
            child: Text('No models match "$_filter".', style: theme.textTheme.bodyMedium),
          )
        : null;
    return RadioGroup<String>(
      groupValue: widget.selectedId,
      onChanged: (id) {
        if (id != null) widget.onSelected(id);
      },
      child: widget.shrinkWrap
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [?filter, ?empty, ...tiles])
          : Column(
              children: [
                ?filter,
                ?empty,
                Expanded(child: ListView(children: tiles)),
              ],
            ),
    );
  }

  Widget? _subtitle(ModelDescriptor m, ThemeData theme) {
    final parts = <String>[
      if (m.displayName != m.id) m.id,
      if (m.capabilities.contextLength != ModelCapabilities.unknown.contextLength)
        '${_compact(m.capabilities.contextLength)} context',
      if (m.capabilities.vision) 'vision',
      if (m.capabilities.reasoning != ReasoningSupport.none) 'reasoning',
    ];
    if (m.description != null) parts.add(m.description!);
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.metricSmall.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  static String _compact(int tokens) =>
      tokens >= 1000000 ? '${(tokens / 1000000).toStringAsFixed(tokens % 1000000 == 0 ? 0 : 1)}M' : '${tokens ~/ 1000}k';
}

/// Picks a sensible default: the preset's preferred model if listed, else
/// the first one.
String? suggestModel(List<ModelDescriptor> models, {List<String> preferred = const []}) {
  for (final p in preferred) {
    for (final m in models) {
      if (m.id == p) return m.id;
    }
  }
  return models.isEmpty ? null : models.first.id;
}

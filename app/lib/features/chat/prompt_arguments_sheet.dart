import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../services/mcp/composer_sources.dart';

/// The arguments of an MCP prompt, as a form: shown when a slash command
/// is sent without a required argument. Labels and descriptions are the
/// server's text and are presented as coming from it.
///
/// ```dart
/// final values = await PromptArgumentsSheet.show(context, command: c, initial: parsed);
/// ```
class PromptArgumentsSheet extends StatefulWidget {
  const PromptArgumentsSheet({super.key, required this.command, this.initial = const {}, this.missing = const []});

  final McpPromptCommand command;
  final Map<String, String> initial;

  /// Required arguments that were not filled in (highlighted at first).
  final List<String> missing;

  /// The filled-in values, or null when dismissed.
  static Future<Map<String, String>?> show(
    BuildContext context, {
    required McpPromptCommand command,
    Map<String, String> initial = const {},
    List<String> missing = const [],
  }) =>
      showModalBottomSheet<Map<String, String>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => PromptArgumentsSheet(command: command, initial: initial, missing: missing),
      );

  @override
  State<PromptArgumentsSheet> createState() => _PromptArgumentsSheetState();
}

class _PromptArgumentsSheetState extends State<PromptArgumentsSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final a in widget.command.arguments) a.name: TextEditingController(text: widget.initial[a.name] ?? ''),
  };
  bool _tried = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {for (final e in _fields.entries) e.key: e.value.text};

  void _submit() {
    if (widget.command.missing(_values).isNotEmpty) {
      setState(() => _tried = true);
      return;
    }
    Navigator.of(context).pop(_values);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final c = widget.command;
    final missing = {...c.missing(_values), if (!_tried) ...widget.missing.where((m) => (_values[m] ?? '').trim().isEmpty)};
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(headingLevel: 2, child: Text('/${c.command}', style: theme.textTheme.titleLarge)),
            SizedBox(height: t.space.xs),
            Row(
              children: [
                Icon(c.trusted ? Icons.extension_outlined : Icons.gpp_maybe_outlined, size: 16, color: c.trusted ? theme.colorScheme.onSurfaceVariant : t.semantic.warning),
                SizedBox(width: t.space.xs),
                Expanded(
                  child: Text(
                    c.trusted
                        ? 'A prompt from ${c.serverName}.'
                        : 'A prompt from ${c.serverName}. Its text is treated as untrusted content.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (c.description != null) ...[
              SizedBox(height: t.space.sm),
              Text(c.description!, style: theme.textTheme.bodyMedium),
            ],
            SizedBox(height: t.space.lg),
            for (final (i, a) in c.arguments.indexed) ...[
              TextField(
                controller: _fields[a.name],
                autofocus: i == 0 || (missing.isNotEmpty && a.name == missing.first),
                textInputAction: i == c.arguments.length - 1 ? TextInputAction.done : TextInputAction.next,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => i == c.arguments.length - 1 ? _submit() : null,
                decoration: InputDecoration(
                  labelText: '${a.title ?? a.name}${a.required ? '' : ' (optional)'}',
                  helperText: a.description,
                  helperMaxLines: 3,
                  errorText: _tried && missing.contains(a.name) ? 'Required' : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              SizedBox(height: t.space.md),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.arrow_upward_rounded),
                label: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

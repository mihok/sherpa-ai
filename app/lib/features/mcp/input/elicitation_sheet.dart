import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../services/mcp/input/elicitation_form.dart';
import '../../../services/mcp/input/input_queue.dart';
import '../../../state/ui_preferences.dart';
import '../widgets/mcp_widgets.dart';
import 'server_content.dart';

/// A form-mode elicitation as a native form (client/elicitation.md MUSTs):
/// it says which server is asking, lets the user review and edit every
/// answer, and offers Send, Decline (an explicit no) and Cancel (dismiss
/// without choosing). Closing the sheet keeps the request waiting.
///
/// Everything the server wrote — its message, field titles and
/// descriptions, choices — sits inside a [ServerContentPanel]; buttons and
/// warnings are Sherpa's own.
class ElicitationFormSheet extends ConsumerStatefulWidget {
  const ElicitationFormSheet({super.key, required this.pending});

  final PendingFormElicitation pending;

  @override
  ConsumerState<ElicitationFormSheet> createState() => _ElicitationFormSheetState();
}

class _ElicitationFormSheetState extends ConsumerState<ElicitationFormSheet> {
  late final Map<String, Object?> _values = widget.pending.form.initialValues();
  final Map<String, TextEditingController> _text = {};
  Map<String, String> _errors = const {};
  bool _tried = false;

  PendingFormElicitation get _p => widget.pending;

  @override
  void initState() {
    super.initState();
    for (final f in _p.form.fields) {
      if (f.kind == ElicitationFieldKind.text || f.kind == ElicitationFieldKind.number || f.kind == ElicitationFieldKind.integer) {
        _text[f.key] = TextEditingController(text: (_values[f.key] as String?) ?? '')
          ..addListener(() => _set(f.key, _text[f.key]!.text, rebuild: false));
      }
    }
    _p.addListener(_onPending);
  }

  @override
  void dispose() {
    _p.removeListener(_onPending);
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onPending() {
    // Answered elsewhere, timed out or its call was cancelled: close.
    if (_p.isDone && mounted) Navigator.of(context).maybePop();
  }

  void _set(String key, Object? value, {bool rebuild = true}) {
    _values[key] = value;
    if (_tried) {
      final errors = _p.form.validate(_values);
      if (rebuild || errors.length != _errors.length) {
        setState(() => _errors = errors);
      } else {
        _errors = errors;
      }
    } else if (rebuild) {
      setState(() {});
    }
  }

  void _send() {
    final errors = _p.form.validate(_values);
    if (errors.isNotEmpty) {
      ref.read(hapticsProvider).error();
      setState(() {
        _tried = true;
        _errors = errors;
      });
      return;
    }
    if (_p.accept(_values)) ref.read(hapticsProvider).success();
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final form = _p.form;
    final message = safeServerText(_p.request.message);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.md),
              children: [
                InputRequesterHeader(
                  title: 'A tool server needs your input',
                  serverName: _p.serverName,
                  trusted: _p.serverTrusted,
                  toolName: _p.toolName,
                ),
                SizedBox(height: t.space.lg),
                ServerContentPanel(
                  serverName: _p.serverName,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (message.isNotEmpty) ...[
                        Text(message, style: theme.textTheme.bodyLarge),
                        SizedBox(height: t.space.md),
                      ],
                      if (form.fields.isEmpty)
                        Text('No questions: the server only asks you to confirm.', style: theme.textTheme.bodyMedium)
                      else
                        for (final f in form.fields) ...[
                          _FieldView(
                            field: f,
                            value: _values[f.key],
                            error: _errors[f.key],
                            controller: _text[f.key],
                            onChanged: (v) => _set(f.key, v),
                          ),
                          SizedBox(height: t.space.md),
                        ],
                    ],
                  ),
                ),
                if (form.unsupported.isNotEmpty) ...[
                  SizedBox(height: t.space.md),
                  NoteBox(
                    tone: form.unsupportedRequired.isEmpty ? NoteTone.neutral : NoteTone.danger,
                    icon: Icons.help_outline_rounded,
                    text: form.unsupportedRequired.isEmpty
                        ? 'Sherpa left out ${form.unsupported.length} question${form.unsupported.length == 1 ? '' : 's'} '
                            "it can't show. They are sent unanswered."
                        : "This form asks for something Sherpa can't show, so it can't be sent. You can decline it.",
                  ),
                ],
                SizedBox(height: t.space.md),
                Text(
                  'Only what you enter here is sent to ${_p.serverName}. Fields marked * are required.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.md),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: t.space.sm,
                runSpacing: t.space.sm,
                children: [
                  TextButton(onPressed: _p.cancel, child: const Text('Cancel')),
                  OutlinedButton(onPressed: _p.decline, child: const Text('Decline')),
                  FilledButton.icon(
                    onPressed: form.canAccept ? _send : null,
                    icon: const Icon(Icons.send_rounded),
                    label: Text('Send to ${_short(_p.serverName)}'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _short(String s) => s.length > 24 ? '${s.substring(0, 23)}…' : s;
}

class _FieldView extends StatelessWidget {
  const _FieldView({required this.field, required this.value, required this.error, required this.controller, required this.onChanged});

  final ElicitationField field;
  final Object? value;
  final String? error;
  final TextEditingController? controller;
  final ValueChanged<Object?> onChanged;

  String get _label => '${safeServerText(field.label, max: 120, keepNewlines: false)}${field.required ? ' *' : ''}';

  String? get _help => field.description == null ? null : safeServerText(field.description!, max: 400);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = SherpaTokens.of(context);
    switch (field.kind) {
      case ElicitationFieldKind.text || ElicitationFieldKind.number || ElicitationFieldKind.integer:
        final numeric = field.kind != ElicitationFieldKind.text;
        final date = field.format == ElicitationTextFormat.date;
        return TextField(
            key: ValueKey('elicit-${field.key}'),
            controller: controller,
            // URLs and addresses are never linkified (R01 §7.1).
            enableInteractiveSelection: true,
            autocorrect: false,
            keyboardType: numeric
                ? TextInputType.numberWithOptions(signed: true, decimal: field.kind == ElicitationFieldKind.number)
                : switch (field.format) {
                    ElicitationTextFormat.email => TextInputType.emailAddress,
                    ElicitationTextFormat.uri => TextInputType.url,
                    ElicitationTextFormat.date || ElicitationTextFormat.dateTime => TextInputType.datetime,
                    ElicitationTextFormat.plain => TextInputType.text,
                  },
            inputFormatters: [
              if (field.kind == ElicitationFieldKind.integer) FilteringTextInputFormatter.allow(RegExp(r'[-0-9]')),
              if (field.kind == ElicitationFieldKind.number) FilteringTextInputFormatter.allow(RegExp(r'[-0-9.eE+]')),
            ],
            maxLines: numeric || field.format != ElicitationTextFormat.plain ? 1 : null,
            minLines: 1,
            decoration: InputDecoration(
              labelText: _label,
              helperText: _help ?? _hint(field),
              helperMaxLines: 4,
              errorText: error,
              border: const OutlineInputBorder(),
              suffixIcon: date
                  ? IconButton(
                      tooltip: 'Pick a date',
                      icon: const Icon(Icons.calendar_today_outlined),
                      onPressed: () => unawaited(_pickDate(context)),
                    )
                  : null,
            ),
          );
      case ElicitationFieldKind.boolean:
        return MergeSemantics(
          child: CheckboxListTile(
            key: ValueKey('elicit-${field.key}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: value == true,
            onChanged: (v) => onChanged(v ?? false),
            title: Text(_label),
            subtitle: _help == null ? null : Text(_help!),
          ),
        );
      case ElicitationFieldKind.singleChoice:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_label, style: theme.textTheme.titleSmall),
            if (_help != null) Text(_help!, style: theme.textTheme.bodySmall),
            SizedBox(height: t.space.xs),
            Wrap(
              spacing: t.space.xs,
              runSpacing: t.space.xs,
              children: [
                for (final o in field.options)
                  ChoiceChip(
                    key: ValueKey('elicit-${field.key}-${o.value}'),
                    label: Text(safeServerText(o.label, max: 80, keepNewlines: false)),
                    selected: value == o.value,
                    onSelected: (on) => onChanged(on ? o.value : (field.required ? value : null)),
                  ),
              ],
            ),
            if (error != null) _ErrorLine(error!),
          ],
        );
      case ElicitationFieldKind.multiChoice:
        final selected = value is List ? [for (final v in value! as List) '$v'] : <String>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_label, style: theme.textTheme.titleSmall),
            if (_help != null) Text(_help!, style: theme.textTheme.bodySmall),
            SizedBox(height: t.space.xs),
            Wrap(
              spacing: t.space.xs,
              runSpacing: t.space.xs,
              children: [
                for (final o in field.options)
                  FilterChip(
                    key: ValueKey('elicit-${field.key}-${o.value}'),
                    label: Text(safeServerText(o.label, max: 80, keepNewlines: false)),
                    selected: selected.contains(o.value),
                    onSelected: (on) => onChanged([
                      for (final x in field.options)
                        if (x.value == o.value ? on : selected.contains(x.value)) x.value,
                    ]),
                  ),
              ],
            ),
            if (error != null) _ErrorLine(error!),
          ],
        );
    }
  }

  static String? _hint(ElicitationField f) => switch (f.format) {
        ElicitationTextFormat.email => 'An email address',
        ElicitationTextFormat.uri => 'A web address',
        ElicitationTextFormat.date => 'YYYY-MM-DD',
        ElicitationTextFormat.dateTime => 'YYYY-MM-DDTHH:MM',
        ElicitationTextFormat.plain => switch (f.kind) {
            ElicitationFieldKind.integer => 'A whole number',
            ElicitationFieldKind.number => 'A number',
            _ => null,
          },
      };

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller?.text ?? '');
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year + 100),
    );
    if (picked == null) return;
    String two(int n) => n.toString().padLeft(2, '0');
    controller?.text = '${picked.year.toString().padLeft(4, '0')}-${two(picked.month)}-${two(picked.day)}';
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Semantics(
          liveRegion: true,
          child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
        ),
      );
}

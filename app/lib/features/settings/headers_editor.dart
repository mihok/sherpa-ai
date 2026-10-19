import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../providers/provider_validation.dart';

/// Editable list of extra, non-secret HTTP headers (e.g.
/// `OpenAI-Organization`, `HTTP-Referer`).
///
/// Anything that looks like a credential is rejected with a pointer to the
/// key field: headers are stored as plain app data, keys go to the
/// Keychain/Keystore.
class HeadersEditor extends StatefulWidget {
  const HeadersEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.keyFieldLabel,
    this.showAllErrors = false,
  });

  final Map<String, String> initial;
  final ValueChanged<List<HeaderRow>> onChanged;
  final String keyFieldLabel;

  /// Show errors on untouched rows too (after a save attempt).
  final bool showAllErrors;

  @override
  State<HeadersEditor> createState() => _HeadersEditorState();
}

class _Row {
  _Row(String name, String value)
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  bool touched = false;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _HeadersEditorState extends State<HeadersEditor> {
  late final List<_Row> _rows = [for (final e in widget.initial.entries) _Row(e.key, e.value)];

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  List<HeaderRow> get _values => [for (final r in _rows) (name: r.name.text, value: r.value.text)];

  void _changed() {
    setState(() {});
    widget.onChanged(_values);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final values = _values;
    final validated = validateHeaders(values, keyFieldLabel: widget.keyFieldLabel);
    // A fully blank row is just an unused "Add header" slot, not an error.
    final errors = <({String? name, String? value})>[
      for (final (i, v) in values.indexed)
        v.name.trim().isEmpty && v.value.trim().isEmpty ? (name: null, value: null) : validated[i],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in _rows.indexed)
          Padding(
            padding: EdgeInsets.only(bottom: t.space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: r.name,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'Header name',
                          hintText: 'OpenAI-Organization',
                          errorText: r.touched || widget.showAllErrors ? errors[i].name : null,
                        ),
                        onChanged: (_) {
                          r.touched = true;
                          _changed();
                        },
                      ),
                      SizedBox(height: t.space.sm),
                      TextField(
                        controller: r.value,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'Value',
                          errorText: r.touched || widget.showAllErrors ? errors[i].value : null,
                        ),
                        onChanged: (_) {
                          r.touched = true;
                          _changed();
                        },
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: r.name.text.trim().isEmpty ? 'Remove header ${i + 1}' : 'Remove header ${r.name.text.trim()}',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () {
                    _rows.removeAt(i).dispose();
                    _changed();
                  },
                ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () {
              _rows.add(_Row('', ''));
              _changed();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add header'),
          ),
        ),
      ],
    );
  }
}

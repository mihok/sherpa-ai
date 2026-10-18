import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';

/// Where secrets are kept, in the platform's own words.
String get secureStoreName => switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'Keychain',
      TargetPlatform.android => 'Android Keystore',
      _ => 'secure storage',
    };

/// Obscured API key input with show/hide and paste.
///
/// - No autocorrect, suggestions or autofill: keyboards must not learn keys.
/// - The value is never logged and never pre-filled from storage; editing a
///   provider shows "Saved in Keychain/Keystore" instead (see [SavedKeyTile]).
/// - Wrapped in [SensitiveContent] so Android 15+ blanks it during screen
///   sharing (a no-op elsewhere).
class ApiKeyField extends StatefulWidget {
  const ApiKeyField({
    super.key,
    required this.controller,
    this.label = 'API key',
    this.hint,
    this.optional = false,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;

  /// Plain-text pointer to where keys come from (no links).
  final String? hint;
  final bool optional;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<ApiKeyField> {
  bool _obscured = true;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    widget.controller.text = text;
    widget.onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.done,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.optional ? '${widget.label} (optional)' : widget.label,
        helperText: widget.hint,
        errorText: widget.errorText,
        prefixIcon: const Icon(Icons.key_outlined),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste),
              onPressed: () => unawaited(_paste()),
            ),
            IconButton(
              tooltip: _obscured ? 'Show key' : 'Hide key',
              icon: Icon(_obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
          ],
        ),
      ),
    );
    // Only Android implements content sensitivity; elsewhere the widget
    // would just add a frame of latency while it asks the platform.
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return field;
    return SensitiveContent(sensitivity: ContentSensitivity.sensitive, child: field);
  }
}

/// Stands in for the key field when a key is already stored.
class SavedKeyTile extends StatelessWidget {
  const SavedKeyTile({super.key, required this.label, required this.onReplace, required this.onRemove});

  final String label;
  final VoidCallback onReplace;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(t.space.md),
        child: Row(
          children: [
            Icon(Icons.lock_outline, color: t.semantic.onDevice),
            SizedBox(width: t.space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    'Saved in $secureStoreName',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Wrap(
              children: [
                TextButton(onPressed: onReplace, child: const Text('Replace')),
                TextButton(onPressed: onRemove, child: const Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Base URL input. Validation lives in `provider_validation.dart`.
class BaseUrlField extends StatelessWidget {
  const BaseUrlField({
    super.key,
    required this.controller,
    this.hint,
    this.errorText,
    this.onChanged,
    this.helperText,
  });

  final TextEditingController controller;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: 'Server address',
          hintText: hint,
          helperText: helperText,
          errorText: errorText,
          prefixIcon: const Icon(Icons.link),
        ),
      );
}

/// The explicit opt-in for http:// and private addresses.
class LocalNetworkToggle extends StatelessWidget {
  const LocalNetworkToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: const Text('This is a server on my own network'),
        subtitle: const Text(
          'Allows http:// and local addresses such as 192.168.x.x or this phone. '
          'Your messages go to that machine.',
        ),
      );
}

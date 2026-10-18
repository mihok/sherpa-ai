import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../state/provider_location.dart';
import '../providers/model_list.dart';
import 'onboarding_scaffold.dart';

/// Step 3: pick the model new chats start with, then go.
class ModelStep extends StatefulWidget {
  const ModelStep({super.key, required this.config, required this.models, required this.onStart});

  final ProviderConfig config;
  final List<ModelDescriptor> models;

  /// Completes when the first chat is open (keeps the button busy until then).
  final Future<void> Function(String modelId) onStart;

  @override
  State<ModelStep> createState() => _ModelStepState();
}

class _ModelStepState extends State<ModelStep> {
  // With a single model there is nothing to decide.
  late String? _selected = widget.models.length == 1 ? widget.models.single.id : widget.config.defaultModelId;
  final TextEditingController _manual = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  String? get _modelId {
    if (widget.models.isEmpty) {
      final typed = _manual.text.trim();
      return typed.isEmpty ? null : typed;
    }
    return _selected;
  }

  Future<void> _start() async {
    final id = _modelId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await widget.onStart(id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final ready = _modelId != null && !_busy;
    return OnboardingStepLayout(
      title: 'Pick a model',
      lead: widget.models.isEmpty
          ? "${widget.config.displayName} didn't list any models. Type the model name you want to use."
          : 'New chats start with this model. You can switch any time, per chat.',
      actions: [
        if (_modelId == null && widget.models.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: t.space.sm),
            child: Text('Choose a model to continue', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          ),
        FilledButton.icon(
          onPressed: ready ? () => unawaited(_start()) : null,
          icon: _busy ? const ButtonSpinner() : const Icon(Icons.arrow_forward),
          label: const Text('Start chatting'),
        ),
      ],
      children: [
        Wrap(
          spacing: t.space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(widget.config.displayName, style: theme.textTheme.titleSmall),
            PrivacyBadge(location: locationOf(widget.config), host: hostLabel(widget.config.baseUrl)),
          ],
        ),
        SizedBox(height: t.space.lg),
        if (widget.models.isEmpty)
          TextField(
            controller: _manual,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Model name', hintText: 'e.g. qwen3:8b'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_start()),
          )
        else
          ModelChoiceList(
            models: widget.models,
            selectedId: _selected,
            shrinkWrap: true,
            onSelected: (id) => setState(() => _selected = id),
          ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../../design/tokens.dart';
import '../../../services/mcp/input/input_queue.dart';
import '../../../services/mcp/input/sampling.dart';
import '../../../state/ui_preferences.dart';
import '../state/input_providers.dart';
import '../widgets/mcp_widgets.dart';
import 'server_content.dart';

/// `modelPreferences` in words (all of it advisory, and server text).
String describeModelPreferences(Map<String, Object?>? prefs) {
  if (prefs == null || prefs.isEmpty) return 'None given';
  String level(Object? v) => v is num ? (v >= 0.67 ? 'high' : (v >= 0.34 ? 'medium' : 'low')) : '';
  final hints = [
    if (prefs['hints'] is List)
      for (final h in prefs['hints']! as List)
        if (h is Map && h['name'] is String) safeServerText(h['name']! as String, max: 40, keepNewlines: false),
  ];
  final parts = [
    if (hints.isNotEmpty) 'models like ${hints.take(4).join(', ')}',
    for (final (k, label) in const [('intelligencePriority', 'quality'), ('speedPriority', 'speed'), ('costPriority', 'low cost')])
      if (prefs[k] is num) '$label: ${level(prefs[k])}',
  ];
  return parts.isEmpty ? 'None given' : parts.join(' · ');
}

/// A sampling request, human in the loop on both sides (client/sampling.md
/// SHOULDs): first what the server wants to send (messages, system prompt,
/// model preferences), the model Sherpa would use and an estimated token
/// cost, with Deny / Allow once / Allow for this chat and an editable
/// prompt; then the model's answer for review before it goes back.
class SamplingSheet extends ConsumerStatefulWidget {
  const SamplingSheet({super.key, required this.pending});

  final PendingSampling pending;

  @override
  ConsumerState<SamplingSheet> createState() => _SamplingSheetState();
}

class _SamplingSheetState extends ConsumerState<SamplingSheet> {
  late final int? _editable = McpSamplingService.editableIndex(widget.pending.request);
  late final TextEditingController _prompt = TextEditingController(
    text: _editable == null ? '' : McpSamplingService.textOf(widget.pending.request.messages[_editable]),
  );
  TextEditingController? _answer;
  Future<SamplingModelPick>? _pick;

  PendingSampling get _p => widget.pending;

  @override
  void initState() {
    super.initState();
    _p.addListener(_onPending);
    _pick = ref.read(mcpSamplingDriverProvider)?.modelFor(_p);
    _prompt.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _p.removeListener(_onPending);
    _prompt.dispose();
    _answer?.dispose();
    super.dispose();
  }

  void _onPending() {
    if (!mounted) return;
    if (_p.isDone) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_p.stage == SamplingStage.review && _answer == null) _answer = TextEditingController(text: _p.draft?.text ?? '');
    setState(() {});
  }

  void _approve({required bool forChat}) {
    final original = _editable == null ? null : McpSamplingService.textOf(_p.request.messages[_editable]);
    final edited = _editable == null || _prompt.text == original ? null : _prompt.text;
    ref.read(hapticsProvider).selection();
    _p.approve(prompt: edited, forChat: forChat);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
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
                  title: switch (_p.stage) {
                    SamplingStage.approval => 'Let a tool server use your model?',
                    SamplingStage.running => 'Writing an answer…',
                    SamplingStage.review => 'Send this answer?',
                    SamplingStage.failed => "The model couldn't answer",
                  },
                  serverName: _p.serverName,
                  trusted: _p.serverTrusted,
                  toolName: _p.toolName,
                ),
                SizedBox(height: t.space.md),
                ...switch (_p.stage) {
                  SamplingStage.approval => _approval(context),
                  SamplingStage.running => _running(context),
                  SamplingStage.review => _review(context),
                  SamplingStage.failed => [NoteBox(text: _p.error ?? 'Unknown error.', tone: NoteTone.danger, icon: Icons.error_outline)],
                },
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
                children: switch (_p.stage) {
                  SamplingStage.approval => [
                      TextButton(onPressed: _p.deny, child: const Text('Deny')),
                      if (_p.sessionId != null)
                        OutlinedButton(onPressed: () => _approve(forChat: true), child: const Text('Allow for this chat')),
                      FilledButton(onPressed: () => _approve(forChat: false), child: const Text('Allow once')),
                    ],
                  SamplingStage.running => [TextButton(onPressed: _p.deny, child: const Text('Stop'))],
                  SamplingStage.review => [
                      TextButton(onPressed: () => _p.deny('The user chose not to send the answer.'), child: const Text("Don't send")),
                      FilledButton.icon(
                        onPressed: () {
                          ref.read(hapticsProvider).success();
                          _p.send(text: _answer?.text);
                        },
                        icon: const Icon(Icons.send_rounded),
                        label: const Text('Send answer'),
                      ),
                    ],
                  SamplingStage.failed => [FilledButton(onPressed: _p.deny, child: const Text('Close'))],
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _approval(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final r = _p.request;
    final limits = _p.limits;
    final service = ref.read(mcpSamplingServiceProvider);
    final edited = _editable == null ? null : _prompt.text;
    final est = service.estimate(r, maxTokens: limits.maxTokens, editedPrompt: edited);
    return [
      FutureBuilder<SamplingModelPick>(
        future: _pick,
        builder: (context, snap) {
          final pick = snap.data;
          return InputFact(
            label: 'Model Sherpa would use${pick == null ? '' : ' (${pick.source.toLowerCase()})'}',
            value: pick == null ? '…' : (pick.label ?? 'None: set up a default model in Settings first'),
            emphasize: true,
          );
        },
      ),
      InputFact(
        label: 'Estimated cost',
        value: '≈ ${est.inputTokens} tokens to read + up to ${est.maxOutputTokens} to write (≈ ${est.totalTokens} in all)',
      ),
      if (limits.capped)
        Padding(
          padding: EdgeInsets.only(top: t.space.xs),
          child: Text(
            'The server asked for up to ${limits.requestedMaxTokens} tokens; your limit for it is ${limits.maxTokens}.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (limits.contextRefused) ...[
        SizedBox(height: t.space.sm),
        const NoteBox(
          icon: Icons.lock_outline_rounded,
          text: 'The server asked to include your conversation. Sherpa never shares it: only the messages below are '
              'sent to the model.',
        ),
      ],
      SizedBox(height: t.space.sm),
      const NoteBox(
        icon: Icons.build_circle_outlined,
        text: 'The model gets no tools for this request, and you review its answer before it is sent back.',
      ),
      SizedBox(height: t.space.md),
      ServerContentPanel(
        serverName: _p.serverName,
        label: 'What ${_p.serverName} wants to send to the model',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.systemPrompt != null && r.systemPrompt!.trim().isNotEmpty) ...[
              Text('Instructions', style: theme.textTheme.labelLarge),
              Text(safeServerText(r.systemPrompt!, max: 4000), style: theme.textTheme.bodyMedium),
              SizedBox(height: t.space.md),
            ],
            for (final (i, m) in r.messages.indexed) ...[
              Text(m.role == 'assistant' ? 'Model' : 'Message', style: theme.textTheme.labelLarge),
              if (i == _editable)
                TextField(
                  key: const ValueKey('sampling-prompt'),
                  controller: _prompt,
                  minLines: 2,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    helperText: 'You can edit this before it is sent.',
                  ),
                )
              else
                Text(_describe(m), style: theme.textTheme.bodyMedium),
              SizedBox(height: t.space.sm),
            ],
            Text('Model preferences', style: theme.textTheme.labelLarge),
            Text(describeModelPreferences(r.modelPreferences), style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    ];
  }

  static String _describe(McpSamplingMessage m) => [
        for (final c in m.content)
          switch (c) {
            McpTextContent(:final text) => safeServerText(text, max: 4000),
            McpImageContent() => '[an image]',
            McpAudioContent() => '[an audio clip]',
            _ => '[${c.type}]',
          },
      ].join('\n');

  List<Widget> _running(BuildContext context) {
    final t = SherpaTokens.of(context);
    return [
      const LinearProgressIndicator(),
      SizedBox(height: t.space.md),
      Text(
        'The model is writing (at most ${_p.limits.maxTokens} tokens). You will see the answer before it is sent.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ];
  }

  List<Widget> _review(BuildContext context) {
    final t = SherpaTokens.of(context);
    final d = _p.draft;
    _answer ??= TextEditingController(text: d?.text ?? '');
    return [
      if (d != null) InputFact(label: 'Written by', value: d.modelLabel),
      if (d?.stopReason == 'maxTokens')
        Padding(
          padding: EdgeInsets.only(top: t.space.xs),
          child: Text('The answer was cut off at the token limit.', style: Theme.of(context).textTheme.bodySmall),
        ),
      SizedBox(height: t.space.sm),
      TextField(
        key: const ValueKey('sampling-answer'),
        controller: _answer,
        minLines: 3,
        maxLines: 16,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: 'Answer for ${_p.serverName}',
          helperText: 'You can edit it. Only this text is sent.',
        ),
      ),
    ];
  }
}

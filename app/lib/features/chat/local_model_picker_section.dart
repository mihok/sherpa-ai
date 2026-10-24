import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../routing/routes.dart';
import '../../services/inference/local_inference.dart';
import '../../services/inference/on_device_ids.dart';
import '../../state/services.dart';
import '../models/state/local_inference_providers.dart';
import '../models/state/local_model_fit.dart';
import '../models/state/model_fit.dart';
import '../models/widgets/format.dart';
import '../models/widgets/pills.dart';
import 'state/model_selection.dart';
import 'widgets/chat_style.dart';

/// The model picker's "On this device" section: every installed model with
/// its fit on this phone right now (Fits / Tight / Won't fit, the same
/// estimate as the download screens) and its engine — llama.cpp for GGUF,
/// MLX (iOS) and LiteRT-LM (Android) with their availability — then the
/// system models (Apple Intelligence, Gemini Nano) with their status.
/// Models that won't fit, have broken files, or can't run because their
/// engine is unavailable or not on this platform are shown disabled with
/// the reason. Gemini Nano says that it only runs while Sherpa is on
/// screen. Renders nothing when on-device inference is not wired.
class LocalModelPickerSection extends ConsumerStatefulWidget {
  const LocalModelPickerSection({super.key, required this.current, required this.onPick});

  /// Shown with a check mark.
  final ModelChoice? current;
  final void Function(ModelChoice choice) onPick;

  @override
  ConsumerState<LocalModelPickerSection> createState() => _LocalModelPickerSectionState();
}

class _LocalModelPickerSectionState extends ConsumerState<LocalModelPickerSection> {
  @override
  void initState() {
    super.initState();
    // Opening the picker is a first use: whether the engine can run here is
    // part of the answer.
    final local = ref.read(localInferenceProvider);
    if (local != null) unawaited(local.start());
  }

  void _browse() {
    final router = GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    router?.push(Routes.modelBrowse);
  }

  @override
  Widget build(BuildContext context) {
    final local = ref.watch(localInferenceProvider);
    if (local == null) return const SizedBox.shrink();
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final status = ref.watch(localEngineStatusProvider).value ?? local.status;
    final options = ref.watch(localModelOptionsProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget line(IconData icon, String text, {Color? color}) => Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: ChatIconSize.medium, color: color ?? theme.colorScheme.onSurfaceVariant),
              SizedBox(width: tokens.space.sm),
              Expanded(child: Text(text, style: muted)),
            ],
          ),
        );

    final crash = status.crashReport;
    final list = options.value;
    final system = ref.watch(systemModelOptionsProvider).value ?? const <SystemModelOption>[];
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.lg),
      child: HeadingGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.xs),
              child: Wrap(
                spacing: tokens.space.md,
                runSpacing: tokens.space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Heading(level: 3, child: Text('On this device', style: theme.textTheme.titleSmall)),
                  const PrivacyBadge(location: ExecutionLocation.onDevice),
                ],
              ),
            ),
            if (status.state == LocalEngineState.starting) line(Icons.hourglass_top_rounded, 'Starting the on-device engine…'),
            if (status.unavailableMessage != null)
              line(Icons.memory_rounded, status.unavailableMessage!, color: tokens.semantic.warning),
            if (crash != null) line(Icons.report_problem_outlined, 'Last time: ${crash.description}', color: tokens.semantic.warning),
            if (list == null && options.hasError)
              line(Icons.error_outline_rounded, "Couldn't read the models on this phone.")
            else if (list == null)
              Padding(
                padding: EdgeInsets.all(tokens.space.md),
                child: Row(
                  children: [
                    SizedBox.square(dimension: ChatIconSize.medium, child: const CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: tokens.space.md),
                    // Wraps at large text instead of running off the sheet.
                    const Expanded(child: Text('Checking which models fit…')),
                  ],
                ),
              )
            else if (list.isEmpty && system.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
                child: Row(
                  children: [
                    Expanded(child: Text('No models on this phone yet.', style: muted)),
                    TextButton(onPressed: _browse, child: const Text('Browse models')),
                  ],
                ),
              )
            else
              for (final o in list)
                _LocalModelRow(
                  key: ValueKey('local-model-${o.model.id}'),
                  option: o,
                  selected: widget.current == o.choice,
                  onTap: o.selectable ? () => widget.onPick(o.choice) : null,
                ),
            for (final o in system)
              _SystemModelRow(
                key: ValueKey('system-model-${o.providerId}'),
                option: o,
                selected: widget.current == o.choice,
                onTap: o.selectable ? () => widget.onPick(o.choice) : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _LocalModelRow extends StatelessWidget {
  const _LocalModelRow({super.key, required this.option, required this.selected, required this.onTap});

  final LocalModelOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final o = option;
    final caps = o.descriptor.capabilities;
    final enabled = onTap != null;
    final engine = switch (o.choice.providerId) {
      mlxProviderId => 'MLX',
      liteRtProviderId => 'LiteRT',
      _ => null,
    };
    final facts = [
      ?engine,
      '${formatTokenCount(caps.contextLength)} context',
      if (!caps.canCallTools) 'no tools',
      if (caps.reasoning != ReasoningSupport.none) 'reasoning',
      ?o.model.quant,
      formatBytes(o.model.sizeBytes),
    ].join(' · ');
    final reason = o.unavailableReason;
    final fitLabel = switch (o.fit) {
      FitBadgeKind.fits => 'Fits',
      FitBadgeKind.tight => 'Tight',
      FitBadgeKind.wontFit => "Won't fit",
      FitBadgeKind.unknown => 'Fit unknown',
      FitBadgeKind.blocked => 'Unavailable',
      FitBadgeKind.unsupported => "Can't run here",
    };
    final spoken = [
      o.model.displayName,
      facts,
      'Device fit: $fitLabel. ${o.fitReason}',
      ?o.engineNote,
      if (reason != null && reason != o.fitReason) reason,
      if (!enabled) 'Not available',
      const PrivacyBadgeData(location: ExecutionLocation.onDevice).description,
    ].join('. ');
    final onSurface = enabled ? null : theme.disabledColor;
    // A real button node (null onTap when disabled), so screen readers
    // activate the row itself.
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      onTap: onTap,
      label: spoken,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radius.md),
        child: Container(
          constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.sm),
          decoration: selected
              ? BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(tokens.radius.md))
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : enabled
                        ? Icons.radio_button_unchecked_rounded
                        : Icons.block_rounded,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
              SizedBox(width: tokens.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: tokens.space.sm,
                      runSpacing: tokens.space.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(o.model.displayName, style: theme.textTheme.bodyLarge?.copyWith(color: onSurface)),
                        FitBadge(kind: o.fit, explanation: o.fitReason),
                        if (o.loaded)
                          const InfoPill(label: 'Loaded', icon: Icons.bolt_rounded, explanation: 'Already in memory: replies start right away'),
                      ],
                    ),
                    Text(facts, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    if (reason != null)
                      Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: tokens.semantic.danger))
                    else if (o.fit == FitBadgeKind.tight)
                      Text(o.fitReason, style: theme.textTheme.bodySmall?.copyWith(color: tokens.semantic.warning))
                    else if (o.engineNote != null)
                      Text(o.engineNote!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Apple Intelligence or Gemini Nano: its status, and for Gemini Nano that
/// it only runs while Sherpa is on screen (so the choice is never a silent
/// one for background work).
class _SystemModelRow extends StatelessWidget {
  const _SystemModelRow({super.key, required this.option, required this.selected, required this.onTap});

  final SystemModelOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final o = option;
    final enabled = onTap != null;
    final reason = o.unavailableReason;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final spoken = [
      o.name,
      'System model',
      o.availability.reason,
      if (reason != null && reason != o.availability.reason) reason,
      if (o.foregroundOnly) 'Only while Sherpa is on screen',
      if (!enabled) 'Not available',
      const PrivacyBadgeData(location: ExecutionLocation.onDevice).description,
    ].join('. ');
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      onTap: onTap,
      label: spoken,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radius.md),
        child: Container(
          constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.sm),
          decoration: selected
              ? BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(tokens.radius.md))
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : enabled
                        ? Icons.radio_button_unchecked_rounded
                        : Icons.block_rounded,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
              SizedBox(width: tokens.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: tokens.space.sm,
                      runSpacing: tokens.space.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(o.name, style: theme.textTheme.bodyLarge?.copyWith(color: enabled ? null : theme.disabledColor)),
                        const InfoPill(
                          label: 'System',
                          icon: Icons.phone_android_rounded,
                          explanation: "Built into this phone's operating system; nothing to download from Hugging Face.",
                        ),
                        if (o.foregroundOnly)
                          const InfoPill(
                            label: 'On screen only',
                            icon: Icons.visibility_outlined,
                            tone: PillTone.warning,
                            explanation: kForegroundOnlyExplanation,
                          ),
                      ],
                    ),
                    if (reason != null)
                      Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: tokens.semantic.danger))
                    else
                      Text(o.availability.reason, style: muted),
                    if (o.foregroundOnly && enabled) Text('Pauses when you leave Sherpa; continues when you come back.', style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

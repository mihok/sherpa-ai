import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../routing/routes.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import '../../state/sessions.dart';
import '../providers/connection.dart';
import '../providers/preset_picker.dart';
import '../providers/presets.dart';
import 'connect_step.dart';
import 'model_step.dart';
import 'onboarding_scaffold.dart';
import 'welcome_step.dart';

enum OnboardingStep { welcome, choose, connect, model }

/// First run, designed for a first successful chat in under two minutes:
/// welcome → where to run → key/address → model → chat.
///
/// Back (button, gesture or predictive back) steps backwards through the
/// flow; only the welcome step lets the system pop.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  OnboardingStep _step = OnboardingStep.welcome;
  ProviderPreset? _preset;
  ConnectionResult? _connection;

  void _go(OnboardingStep step) => setState(() => _step = step);

  void _back() {
    if (_step != OnboardingStep.welcome) _go(OnboardingStep.values[_step.index - 1]);
  }

  /// Providers that never connected are dropped when the user moves on, so a
  /// typo during setup doesn't leave a broken entry in settings.
  Future<void> _discardFailedProvider() async {
    final c = _connection;
    if (c == null || c.ok) return;
    _connection = null;
    await ref.read(providerRegistryProvider).remove(c.config.id);
  }

  void _choose(ProviderPreset preset) {
    if (preset.id != _preset?.id) {
      unawaited(_discardFailedProvider());
      if (_connection?.ok ?? false) _connection = null; // keep it saved, start fresh
    }
    _preset = preset;
    _go(OnboardingStep.connect);
  }

  void _onResult(ConnectionResult result) {
    _connection = result;
    if (result.ok) {
      _go(OnboardingStep.model);
    } else {
      setState(() {});
    }
  }

  Future<void> _skip() async {
    await _discardFailedProvider();
    await ref.read(preferencesProvider).setOnboardingComplete(true);
    if (mounted) context.go(Routes.home);
  }

  Future<void> _start(String modelId) async {
    final registry = ref.read(providerRegistryProvider);
    final prefs = ref.read(preferencesProvider);
    final config = _connection!.config.copyWith(defaultModelId: modelId);
    await registry.update(config);
    final choice = ModelChoice(providerId: config.id, modelId: modelId);
    await prefs.setDefaultModel(choice);
    final session = await ref.read(sessionActionsProvider).create(model: choice);
    await prefs.setOnboardingComplete(true);
    if (mounted) context.go(Routes.chat(session.id));
  }

  @override
  Widget build(BuildContext context) {
    final motion = SherpaTokens.of(context).motion;
    final stepIndex = _step.index; // 1..3 for the steps after welcome
    return PopScope(
      canPop: _step == OnboardingStep.welcome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: _step == OnboardingStep.welcome
            ? null
            : AppBar(
                leading: BackButton(onPressed: _back),
                title: Text('Step $stepIndex of 3'),
                actions: [TextButton(onPressed: () => unawaited(_skip()), child: const Text('Skip'))],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: Semantics(
                    label: 'Setup progress',
                    value: 'Step $stepIndex of 3',
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: stepIndex / 3),
                      duration: motion.medium,
                      curve: motion.standard,
                      builder: (context, v, _) => LinearProgressIndicator(value: v),
                    ),
                  ),
                ),
              ),
        body: SafeArea(
          top: _step == OnboardingStep.welcome,
          child: AnimatedSwitcher(
            duration: motion.medium,
            switchInCurve: motion.decelerate,
            switchOutCurve: motion.accelerate,
            child: KeyedSubtree(key: ValueKey(_step), child: _buildStep()),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() => switch (_step) {
        OnboardingStep.welcome => WelcomeStep(
            onStart: () => _go(OnboardingStep.choose),
            onSkip: () => unawaited(_skip()),
          ),
        OnboardingStep.choose => OnboardingStepLayout(
            title: 'Where should your models run?',
            lead: 'Pick a service you have a key for, or a model server you run yourself.',
            actions: const [],
            children: [PresetPicker(onSelected: _choose)],
          ),
        OnboardingStep.connect => ConnectStep(
            preset: _preset!,
            existing: _connection?.config,
            onResult: _onResult,
          ),
        OnboardingStep.model => ModelStep(
            config: _connection!.config,
            models: _connection!.models,
            onStart: _start,
          ),
      };
}

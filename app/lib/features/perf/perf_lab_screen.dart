import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/widgets/state_views.dart';
import '../../services/inference/local_inference.dart';
import '../../services/inference/local_model_specs.dart' show isRunnableLocally;
import '../models/state/local_inference_providers.dart';
import 'state/perf_lab.dart';
import 'state/perf_providers.dart';
import 'widgets/bench_tab.dart';
import 'widgets/compare_tab.dart';
import 'widgets/overview_tab.dart';

/// The performance lab of one on-device model: what this phone and engine
/// are, the tuned settings and their memory, a benchmark with history, an
/// A/B tester that can pin the winner, autotune, and a live monitor.
///
/// Everything it runs is background work on the engine's scheduler: it
/// waits for, and gives way to, chat replies (see [PerfLab]).
class PerfLabScreen extends ConsumerWidget {
  const PerfLabScreen({super.key, required this.modelId});

  /// Library id of the model.
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localInferenceProvider);
    final status = ref.watch(localEngineStatusProvider).value;
    final models = ref.watch(localLibraryModelsProvider).value;
    final model = models?.where((m) => m.id == modelId).firstOrNull;
    final title = model == null ? 'Performance' : 'Performance: ${model.displayName}';

    Widget? blocked;
    if (local == null) {
      blocked = const StateView(
        icon: Icons.memory_rounded,
        title: 'On-device models aren’t set up',
        message: 'This build runs without the on-device engine, so there is nothing to measure.',
      );
    } else if (models != null && model == null) {
      blocked = const StateView(
        icon: Icons.search_off_rounded,
        title: 'This model isn’t in your library',
        message: 'It may have been deleted.',
      );
    } else if (model != null && !isRunnableLocally(model)) {
      blocked = StateView(
        icon: Icons.block_rounded,
        title: 'This model can’t run on the on-device engine',
        message: model.usable ? 'The performance lab works with GGUF models.' : model.issue.message,
      );
    } else if (status?.isUnavailable ?? false) {
      blocked = EngineUnavailableView(status: status!);
    }

    final scaleUp = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Semantics(headingLevel: 1, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          bottom: blocked != null
              ? null
              : TabBar(
                  isScrollable: scaleUp,
                  tabAlignment: scaleUp ? TabAlignment.start : null,
                  tabs: const [Tab(text: 'Overview'), Tab(text: 'Benchmark'), Tab(text: 'Compare')],
                ),
        ),
        body: blocked ?? _Lab(modelId: modelId),
      ),
    );
  }
}

/// Why the engine can't run, with "Try again" after a crash loop.
class EngineUnavailableView extends ConsumerWidget {
  const EngineUnavailableView({super.key, required this.status});

  final LocalEngineStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) => StateView(
        icon: Icons.memory_rounded,
        tone: StateTone.warning,
        liveRegion: true,
        title: 'The on-device engine isn’t available',
        message: '${status.unavailableMessage ?? 'The engine did not start.'} Nothing can be measured until it runs.',
        primaryAction: status.canRetry
            ? FilledButton.tonal(
                onPressed: () => unawaited(ref.read(localInferenceProvider)?.retryEngine()),
                child: const Text('Try again'),
              )
            : null,
      );
}

class _Lab extends ConsumerWidget {
  const _Lab({required this.modelId});

  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(perfOverviewProvider(modelId));
    // Keep the lab's state while the screen is open, across tab switches.
    ref.watch(perfLabControllerProvider(modelId).select((s) => s.job?.kind));
    final o = overview.value;
    if (o == null) {
      final e = overview.error;
      if (e == null) return const LoadingState(label: 'Reading the engine…');
      if (e is PerfLabException && e.unavailable) {
        final status = ref.read(localEngineStatusProvider).value;
        return status == null
            ? StateView(icon: Icons.memory_rounded, title: 'The on-device engine isn’t available', message: e.message)
            : EngineUnavailableView(status: status);
      }
      return ErrorState(
        title: 'Couldn’t read the engine',
        message: e is PerfLabException ? e.message : '$e',
        onRetry: () => ref.invalidate(perfOverviewProvider(modelId)),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: TabBarView(
          children: [
            OverviewTab(overview: o),
            BenchTab(overview: o),
            CompareTab(overview: o),
          ],
        ),
      ),
    );
  }
}

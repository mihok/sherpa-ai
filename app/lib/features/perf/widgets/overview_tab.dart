import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show CpuClass, DevicePlatform;
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/section_header.dart';
import '../../../state/providers.dart' show clockProvider;
import '../../models/widgets/format.dart';
import '../../models/widgets/pills.dart';
import '../state/perf_lab.dart' show reportedThermal;
import '../state/perf_models.dart';
import '../state/perf_providers.dart';
import 'perf_common.dart';
import 'perf_format.dart';

/// Device, engine, the live monitor, the tuned profile (with "Re-run
/// autotune") and the memory estimate.
class OverviewTab extends StatelessWidget {
  const OverviewTab({super.key, required this.overview});

  final PerfOverview overview;

  @override
  Widget build(BuildContext context) {
    final o = overview;
    return ListView(
      padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        LiveMonitor(overview: o),
        const SectionHeader('This device'),
        _DeviceCard(o),
        const SectionHeader('Engine'),
        _EngineCard(o.engine),
        const SectionHeader('Tuned settings'),
        JobBanner(modelId: o.modelId, kinds: const {LabJobKind.autotune}),
        LabMessageCard(modelId: o.modelId, kind: LabJobKind.autotune),
        _ProfileCard(o),
        const SectionHeader('Memory'),
        _MemoryCard(o),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Live monitor

/// The most recent on-device generation's PERF numbers, and memory and
/// thermal readings, live while the lab is open.
class LiveMonitor extends ConsumerWidget {
  const LiveMonitor({super.key, required this.overview});

  final PerfOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final mem = ref.watch(perfLiveMemoryProvider).value ?? overview.memory;
    final last = ref.watch(perfLastGenerationProvider).value;
    final now = ref.watch(clockProvider).now();
    final p = last?.perf;
    final d = overview.device;
    final thermal = reportedThermal(mem) ?? (d != null && d.platform != DevicePlatform.other ? d.thermal : null);
    final pressure = switch (mem.pressure) {
      MemoryPressure.normal => ('Normal', PillTone.success),
      MemoryPressure.moderate => ('Moderate', PillTone.warning),
      MemoryPressure.critical => ('Critical', PillTone.danger),
    };
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(headingLevel: 2, child: Text('Live', style: theme.textTheme.titleSmall)),
          SizedBox(height: t.space.xs),
          if (p == null)
            const LabNote('No on-device reply yet since Sherpa started. Chat with a local model and its speed shows here.')
          else ...[
            LabNote(
              'Last reply${last!.modelId == overview.modelId ? '' : ' (another model)'}'
              '${last.background ? ', background work' : ''}, ${formatWhen(last.at, now)}'
              '${p.backend == null ? '' : ' on ${p.backend}'}',
            ),
            Wrap(
              spacing: t.space.lg,
              children: [
                MetricTile(label: 'First token', value: formatMs(p.timeToFirstTokenMs)),
                MetricTile(
                  label: 'Prefill',
                  value: formatTps(p.prefillTokensPerSec),
                  spoken: spokenTps(p.prefillTokensPerSec),
                  detail: p.promptTokens == null
                      ? null
                      : '${p.promptTokens} prompt tokens'
                          '${(p.cachedPromptTokens ?? 0) > 0 ? ', ${p.cachedPromptTokens} cached' : ''}',
                ),
                MetricTile(
                  label: 'Decode',
                  value: formatTps(p.decodeTokensPerSec),
                  spoken: spokenTps(p.decodeTokensPerSec),
                  detail: last.usage == null
                      ? null
                      : '${last.usage!.outputTokens} token${last.usage!.outputTokens == 1 ? '' : 's'}',
                ),
                if (p.draftAcceptRate != null)
                  MetricTile(label: 'Draft accepted', value: formatPercent(p.draftAcceptRate!)),
              ],
            ),
          ],
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              ThermalPill(thermal),
              InfoPill(
                label: pressure.$1,
                icon: Icons.memory_rounded,
                tone: pressure.$2,
                semanticPrefix: 'Memory pressure',
                explanation: 'How hard the system is pushing apps to free memory.',
              ),
              if (mem.availableBytes != null)
                InfoPill(
                  label: '${formatBytes(mem.availableBytes!)} free',
                  icon: Icons.sd_card_outlined,
                  semanticPrefix: 'Available memory',
                  explanation: 'Memory Sherpa can still use before the system steps in.',
                ),
              if (mem.appFootprintBytes != null)
                InfoPill(
                  label: 'App ${formatBytes(mem.appFootprintBytes!)}',
                  icon: Icons.apps_rounded,
                  semanticPrefix: 'App memory',
                  explanation: 'Memory the Sherpa app process uses now.',
                ),
              if (mem.lowPowerMode)
                const InfoPill(
                  label: 'Battery saver',
                  icon: Icons.battery_saver_rounded,
                  tone: PillTone.warning,
                  explanation: 'Battery saver slows the CPU; measurements will be lower.',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Device

class _DeviceCard extends StatelessWidget {
  const _DeviceCard(this.o);

  final PerfOverview o;

  @override
  Widget build(BuildContext context) {
    final d = o.device;
    final sys = o.engine.system;
    final chip = [d?.socManufacturer, d?.socModel].whereType<String>().join(' ');
    final name = d?.displayModel;
    final perfCores = d?.cpu.performanceCores ?? (sys != null && sys.performanceCores > 0 ? sys.performanceCores : null);
    final cores = d != null && d.cpu.cores > 0 ? d.cpu.cores : (sys?.logicalCores ?? 0);
    final features = {...?d?.cpu.features, ...?sys?.cpuFeatures}.toList()..sort();
    final available = d?.availableRamBytes ?? o.memory.availableBytes;
    final total = d?.totalRamBytes ?? o.memory.totalBytes;
    final battery = d?.batteryLevel;
    final platformKnown = d != null && d.platform != DevicePlatform.other;
    return PerfCard(
      child: Column(
        children: [
          FactRow('Device', name ?? 'Not reported'),
          FactRow(
            'Chip',
            chip.isNotEmpty ? chip : (d?.machine ?? d?.hardware ?? 'Not reported'),
          ),
          FactRow(
            'CPU class',
            platformKnown ? _cpuClass(d.cpuClass) : 'Not reported',
            explanation: 'A rough speed tier from the CPU features and clock speed.',
          ),
          FactRow(
            'Performance cores',
            perfCores == null ? (cores > 0 ? '$cores cores' : 'Not reported') : '$perfCores of ${cores > 0 ? cores : '?'}',
            explanation: 'The fast cores. Sherpa uses at most this many threads by default.',
          ),
          if (features.isNotEmpty) FactRow('CPU features', features.join(', ')),
          FactRow('RAM', total == null ? 'Not reported' : formatBytes(total)),
          FactRow(
            'Available now',
            available == null ? 'Not reported' : formatBytes(available),
            explanation: 'What Sherpa can still use before the system steps in.',
          ),
          FactRow('Thermal', thermalLabel(reportedThermal(o.memory) ?? (platformKnown ? d.thermal : null))),
          FactRow(
            'Battery',
            battery == null
                ? 'Not reported'
                : [
                    formatPercent(battery),
                    if (d!.charging ?? false) 'charging',
                    if (d.lowPowerMode || o.memory.lowPowerMode) 'battery saver on',
                  ].join(', '),
          ),
        ],
      ),
    );
  }

  static String _cpuClass(CpuClass c) => switch (c) {
        CpuClass.high => 'High (recent big cores)',
        CpuClass.mid => 'Mid',
        CpuClass.low => 'Low',
      };
}

// ---------------------------------------------------------------------------
// Engine

class _EngineCard extends StatelessWidget {
  const _EngineCard(this.e);

  final EngineDescription e;

  @override
  Widget build(BuildContext context) => PerfCard(
        child: Column(
          children: [
            FactRow('Version', e.version),
            FactRow(
              'Backend',
              e.backendLabel,
              explanation: e.kleidiAi
                  ? 'KleidiAI: Arm’s optimized matrix kernels are in this build.'
                  : 'The CPU kernels this build loaded.',
            ),
            FactRow(
              'Runs',
              e.hostLabel,
              explanation: e.hostKind == EngineHostKind.isolatedProcess
                  ? 'A crash in the engine restarts it without closing the app.'
                  : 'The engine shares the app’s process.',
            ),
            if (e.system?.cpuVariant.isNotEmpty ?? false) FactRow('CPU variant', e.system!.cpuVariant),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Profile

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard(this.o);

  final PerfOverview o;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final busy = ref.watch(perfLabControllerProvider(o.modelId).select((s) => s.busy));
    final controller = ref.read(perfLabControllerProvider(o.modelId).notifier);
    final profile = o.profile;
    final c = o.tuned;
    final ov = o.overrides;
    String mark(bool overridden, String v) => overridden ? '$v (your setting)' : v;
    final (sourceLabel, sourceTone, sourceWhy) = switch (profile?.source) {
      null => ('Not tuned yet', PillTone.neutral, 'Sherpa tunes a model after its first reply, when the phone is idle.'),
      AutotuneSource.measured => ('Measured', PillTone.success, 'Chosen from benchmarks on this phone.'),
      AutotuneSource.override => ('Your settings', PillTone.accent, 'You pinned some settings in the lab.'),
      AutotuneSource.defaults => ('Defaults', PillTone.neutral, 'Nothing could be measured; safe defaults apply.'),
    };
    final hot = (reportedThermal(o.memory)?.index ?? 0) >= ThermalLevel.serious.index;
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              InfoPill(label: sourceLabel, tone: sourceTone, explanation: sourceWhy, semanticPrefix: 'Profile'),
              if (o.hasOverrides && profile == null)
                const InfoPill(
                  label: 'Override waiting',
                  tone: PillTone.warning,
                  explanation: 'Your settings apply on top of a tuned profile. Run autotune once to use them.',
                ),
            ],
          ),
          SizedBox(height: t.space.sm),
          FactRow('Threads', mark(ov.nThreads != null, c.nThreads > 0 ? '${c.nThreads}' : 'Auto')),
          FactRow(
            'Batch / micro-batch',
            mark(ov.nBatch != null || ov.nUbatch != null, '${_auto(c.nBatch)} / ${_auto(c.nUbatch)}'),
            explanation: 'Tokens processed per step while reading the prompt. Bigger is faster to read, '
                'and needs more memory.',
          ),
          FactRow(
            'KV cache',
            mark(ov.typeK != null, c.kv.label),
            explanation: 'How the conversation memory is stored. q8_0 takes about half the space of f16.',
          ),
          FactRow('Flash attention', mark(ov.flashAttention != null, _fa(c.flashAttention))),
          FactRow('Speculative decoding', mark(o.speculative != null, c.speculative.label)),
          if (profile?.measuredAt != null) FactRow('Tuned', formatDateTime(profile!.measuredAt!)),
          if ((profile?.genTokensPerSec ?? 0) > 0)
            FactRow('Measured speed', '${formatTps(profile!.promptTokensPerSec)} prefill, ${formatTps(profile.genTokensPerSec)} decode'),
          if (hot) ...[
            SizedBox(height: t.space.sm),
            LabNote(
              'The phone is hot. Tuning now measures the throttle, not the phone; let it cool down first.',
              icon: Icons.thermostat_rounded,
              color: t.semantic.warning,
            ),
          ],
          SizedBox(height: t.space.md),
          Wrap(
            spacing: t.space.sm,
            runSpacing: t.space.sm,
            children: [
              FilledButton.tonalIcon(
                onPressed: busy ? null : () => unawaited(controller.retune()),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Re-run autotune'),
              ),
              if (o.hasOverrides)
                TextButton(
                  onPressed: busy ? null : () => unawaited(controller.resetToAuto(kind: LabJobKind.autotune)),
                  child: const Text('Reset to auto'),
                ),
            ],
          ),
          SizedBox(height: t.space.xs),
          Text(
            'Autotune benchmarks thread counts, batch sizes and KV types for about a minute, in the background. '
            'A chat reply pauses it.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _auto(int v) => v > 0 ? '$v' : 'auto';
}

String _fa(FlashAttention f) => switch (f) {
      FlashAttention.auto => 'Auto',
      FlashAttention.on => 'On',
      FlashAttention.off => 'Off',
    };

// ---------------------------------------------------------------------------
// Memory

class _MemoryCard extends StatelessWidget {
  const _MemoryCard(this.o);

  final PerfOverview o;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final cur = o.current;
    final e = cur.estimate;
    final b = o.budget;
    final fits = e == null || b.admits(e);
    final fa = cur.flashAttentionOn;
    return PerfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabNote(cur.loaded
              ? 'Loaded now: ${cur.contextTokens}-token context, ${cur.config.summary}.'
              : 'Not loaded. The next load plans a ${cur.contextTokens}-token context with ${cur.config.summary}.'),
          SizedBox(height: t.space.sm),
          if (e != null) ...[
            FactRow('Estimate', formatBytes(e.totalBytes), explanation: 'The engine’s dry run for these settings.'),
            FactRow(
              'Weights',
              '${formatBytes(e.modelBytes)}${e.modelMappedBytes > 0 ? ' (${formatBytes(e.modelMappedBytes)} mapped from the file)' : ''}',
              explanation: 'Mapped weights are read from the file on demand; the system can reclaim them.',
            ),
            FactRow('KV cache', formatBytes(e.kvBytes)),
            FactRow('Compute buffers', formatBytes(e.computeBytes)),
          ],
          if (cur.liveMemory != null) FactRow('Allocated now', formatBytes(cur.liveMemory!.totalBytes)),
          if (fa != null) FactRow('Flash attention', fa ? 'On' : 'Off'),
          FactRow(
            'Budget',
            b.totalBytes == null ? 'Unknown' : formatBytes(b.totalBytes!),
            explanation: 'What a load is admitted against: ${formatPercent(b.fraction)} of the memory available '
                '(${b.source}), minus a safety margin.',
          ),
          if (b.anonymousCapBytes != null) FactRow('Per-app limit', formatBytes(b.anonymousCapBytes!)),
          SizedBox(height: t.space.sm),
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              if (e != null && b.isKnown)
                InfoPill(
                  label: fits ? 'Fits' : 'Over budget',
                  icon: fits ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                  tone: fits ? PillTone.success : PillTone.danger,
                  semanticPrefix: 'Memory',
                ),
            ],
          ),
          if (o.addedBackBytes > 0) ...[
            SizedBox(height: t.space.xs),
            LabNote('The budget counts the ${formatBytes(o.addedBackBytes)} the loaded model uses as free: it is '
                'released before other settings load.'),
          ],
          for (final n in cur.notes) ...[SizedBox(height: t.space.xs), LabNote(n, icon: Icons.info_outline_rounded)],
          if (cur.refusal != null) ...[
            SizedBox(height: t.space.xs),
            LabNote(cur.refusal!, icon: Icons.error_outline_rounded, color: t.semantic.danger),
          ],
        ],
      ),
    );
  }
}

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// How a model family accepts the `thinking` request field (R10 §7.3).
enum AnthropicThinkingStyle {
  /// Thinking is always on: omitting `thinking` means adaptive, and
  /// `disabled` / `budget_tokens` are a 400 (Opus 5.5, Fable, Mythos).
  alwaysOn,

  /// Adaptive by default; the only "off" is `{type: between_tools}`
  /// (no other field, effort at most high). Sonnet 5.5.
  betweenToolsOff,

  /// Adaptive by default; `{type: disabled}` is accepted (at effort ≤ high
  /// on Opus 5 / Haiku 5.5, which is their default). Opus 5, Sonnet 5,
  /// Haiku 5.5.
  adaptive,

  /// Omitting `thinking` means off; adaptive must be requested explicitly.
  /// Opus 4.8 / 4.7 / 4.6, Sonnet 4.6.
  adaptiveOptIn,

  /// Manual `{type: enabled, budget_tokens: N}` (N ≥ 1024, < max_tokens).
  /// Opus/Sonnet/Haiku 4.5 and older 4.x.
  budget,

  /// No extended thinking (Claude 3.x).
  none,
}

/// Values of `output_config.effort`.
enum AnthropicEffort { low, medium, high, xhigh, max }

/// Request-shaping facts about one Anthropic model.
///
/// Several of these cannot be discovered from `/v1/models` (sampling and
/// forced `tool_choice` rejections are not in the capability tree), so a
/// small family table is unavoidable. Discovery refines what it can via
/// [refine]. Unknown ids get [AnthropicModelTraits.unknown], which only uses
/// request shapes every 4.6+ model accepts: no sampling params, no forced
/// tool choice, adaptive thinking, no budgets, no `disabled`.
@immutable
final class AnthropicModelTraits {
  const AnthropicModelTraits({
    required this.thinking,
    required this.effortLevels,
    this.displayDefaultsToOmitted = true,
    this.rejectsSampling = true,
    this.rejectsForcedToolChoice = true,
    this.contextLength = 200000,
    this.maxOutputTokens = 32000,
    this.known = false,
  });

  /// Derives traits from a model id. Accepts dateless ids, dated snapshots
  /// (`claude-opus-4-5-20251101`), platform prefixes (`anthropic.`,
  /// `us.anthropic.`), `[1m]` suffixes and legacy `claude-3-5-sonnet-*`.
  factory AnthropicModelTraits.forModel(String modelId) {
    final id = modelId.toLowerCase();
    final modern = _modern.firstMatch(id);
    if (modern != null) {
      final line = modern.group(1)!;
      final v = _Version(int.parse(modern.group(2)!), int.tryParse(modern.group(3) ?? '') ?? 0);
      return _forLine(line, v);
    }
    if (_legacy.hasMatch(id)) {
      final m = _legacy.firstMatch(id)!;
      final v = _Version(int.parse(m.group(1)!), int.tryParse(m.group(2) ?? '') ?? 0);
      return AnthropicModelTraits(
        thinking: v >= const _Version(3, 7) ? AnthropicThinkingStyle.budget : AnthropicThinkingStyle.none,
        effortLevels: const {},
        displayDefaultsToOmitted: false,
        rejectsSampling: false,
        rejectsForcedToolChoice: false,
        contextLength: 200000,
        maxOutputTokens: 8192,
        known: true,
      );
    }
    return unknown;
  }

  static const Set<AnthropicEffort> _allEfforts = {
    AnthropicEffort.low,
    AnthropicEffort.medium,
    AnthropicEffort.high,
    AnthropicEffort.xhigh,
    AnthropicEffort.max,
  };

  /// Conservative default for ids we cannot place in a family (assumed to
  /// be newer than this table).
  static const AnthropicModelTraits unknown = AnthropicModelTraits(
    thinking: AnthropicThinkingStyle.alwaysOn,
    effortLevels: {AnthropicEffort.low, AnthropicEffort.medium, AnthropicEffort.high},
  );

  static final RegExp _modern = RegExp(r'claude-(opus|sonnet|haiku|fable|mythos)-(\d+)(?:-(\d{1,2}))?(?!\d)');
  static final RegExp _legacy = RegExp(r'claude-(\d)(?:-(\d))?-(opus|sonnet|haiku)');

  static AnthropicModelTraits _forLine(String line, _Version v) {
    const v4_5 = _Version(4, 5);
    const v4_6 = _Version(4, 6);
    const v4_7 = _Version(4, 7);
    const v5 = _Version(5, 0);
    const v5_1 = _Version(5, 1);
    const v5_5 = _Version(5, 5);
    const big = (1000000, 128000);
    final window = v >= v4_6 ? big : (200000, v >= v4_5 ? 64000 : 32000);
    AnthropicModelTraits make(
      AnthropicThinkingStyle thinking,
      Set<AnthropicEffort> effort, {
      required bool rejectsSampling,
      required bool rejectsForced,
      (int, int)? limits,
    }) {
      final (ctx, out) = limits ?? window;
      return AnthropicModelTraits(
        thinking: thinking,
        effortLevels: effort,
        displayDefaultsToOmitted: v >= v4_7,
        rejectsSampling: rejectsSampling,
        rejectsForcedToolChoice: rejectsForced,
        contextLength: ctx,
        maxOutputTokens: out,
        known: true,
      );
    }

    const legacyEffort = {AnthropicEffort.low, AnthropicEffort.medium, AnthropicEffort.high, AnthropicEffort.max};
    switch (line) {
      case 'fable' || 'mythos':
        return make(AnthropicThinkingStyle.alwaysOn, _allEfforts,
            rejectsSampling: true, rejectsForced: v >= v5_1, limits: big);
      case 'opus':
        if (v >= v5_5) {
          return make(AnthropicThinkingStyle.alwaysOn, _allEfforts, rejectsSampling: true, rejectsForced: true);
        }
        if (v >= v5) return make(AnthropicThinkingStyle.adaptive, _allEfforts, rejectsSampling: true, rejectsForced: false);
        if (v >= v4_7) {
          return make(AnthropicThinkingStyle.adaptiveOptIn, _allEfforts, rejectsSampling: true, rejectsForced: false);
        }
        if (v >= v4_6) {
          return make(AnthropicThinkingStyle.adaptiveOptIn, legacyEffort, rejectsSampling: false, rejectsForced: false);
        }
        return make(
          AnthropicThinkingStyle.budget,
          v >= v4_5 ? const {AnthropicEffort.low, AnthropicEffort.medium, AnthropicEffort.high} : const {},
          rejectsSampling: false,
          rejectsForced: false,
        );
      case 'sonnet':
        if (v >= v5_5) {
          return make(AnthropicThinkingStyle.betweenToolsOff, _allEfforts, rejectsSampling: true, rejectsForced: true);
        }
        if (v >= v5) return make(AnthropicThinkingStyle.adaptive, _allEfforts, rejectsSampling: true, rejectsForced: false);
        if (v >= v4_6) {
          return make(AnthropicThinkingStyle.adaptiveOptIn, legacyEffort, rejectsSampling: false, rejectsForced: false);
        }
        return make(AnthropicThinkingStyle.budget, const {}, rejectsSampling: false, rejectsForced: false);
      default: // haiku
        if (v >= v5) {
          return make(AnthropicThinkingStyle.adaptive, _allEfforts,
              rejectsSampling: true, rejectsForced: false, limits: big);
        }
        return make(AnthropicThinkingStyle.budget, const {},
            rejectsSampling: false, rejectsForced: false, limits: (200000, v >= v4_5 ? 64000 : 8192));
    }
  }

  final AnthropicThinkingStyle thinking;

  /// Effort levels `output_config.effort` accepts; empty → never send it.
  final Set<AnthropicEffort> effortLevels;

  /// True on 4.7+ / 5.x, where reasoning text is hidden unless
  /// `display: "summarized"` is sent. Older models reject unknown fields
  /// less predictably, so `display` is only sent where it is needed.
  final bool displayDefaultsToOmitted;

  /// Non-default `temperature`/`top_p`/`top_k` return a 400.
  final bool rejectsSampling;

  /// `tool_choice` `any`/`tool` return a 400.
  final bool rejectsForcedToolChoice;

  /// Static fallbacks used until `/v1/models` answers.
  final int contextLength;
  final int maxOutputTokens;

  /// False for [unknown] (the id did not match any family).
  final bool known;

  bool get supportsAdaptive => switch (thinking) {
        AnthropicThinkingStyle.alwaysOn ||
        AnthropicThinkingStyle.betweenToolsOff ||
        AnthropicThinkingStyle.adaptive ||
        AnthropicThinkingStyle.adaptiveOptIn =>
          true,
        _ => false,
      };

  ReasoningSupport get reasoningSupport => switch (thinking) {
        AnthropicThinkingStyle.alwaysOn => ReasoningSupport.always,
        AnthropicThinkingStyle.none => ReasoningSupport.none,
        _ => ReasoningSupport.optional,
      };

  /// Narrows the static traits with the `capabilities` tree of a
  /// `/v1/models` entry. Only fields present in the tree are used, and only
  /// in the direction the API proves (a level it says is unsupported is
  /// removed; thinking types it says are unsupported change the style).
  AnthropicModelTraits refine(JsonMap? capabilities) {
    if (capabilities == null) return this;
    bool? leaf(JsonMap? node) => node?.opt<bool>('supported');
    var efforts = effortLevels;
    final effort = capabilities.optObj('effort');
    if (effort != null) {
      final declared = {
        for (final e in AnthropicEffort.values)
          if (effort.optObj(e.name) != null) e: leaf(effort.optObj(e.name)) ?? false,
      };
      if (declared.isNotEmpty) {
        efforts = {for (final e in declared.entries) if (e.value) e.key};
      } else if (leaf(effort) == false) {
        efforts = const {};
      }
    }
    var style = thinking;
    final types = capabilities.optObj('thinking')?.optObj('types');
    if (types != null) {
      final adaptive = leaf(types.optObj('adaptive'));
      final enabled = leaf(types.optObj('enabled'));
      final disabled = leaf(types.optObj('disabled'));
      if (adaptive == false && enabled == true) {
        style = AnthropicThinkingStyle.budget;
      } else if (adaptive == false && enabled == false) {
        style = AnthropicThinkingStyle.none;
      } else if (adaptive == true && disabled == false && style == AnthropicThinkingStyle.adaptive) {
        style = AnthropicThinkingStyle.alwaysOn;
      } else if (adaptive == true && !supportsAdaptive) {
        style = AnthropicThinkingStyle.adaptiveOptIn;
      }
    }
    return AnthropicModelTraits(
      thinking: style,
      effortLevels: efforts,
      displayDefaultsToOmitted: displayDefaultsToOmitted,
      rejectsSampling: rejectsSampling,
      rejectsForcedToolChoice: rejectsForcedToolChoice,
      contextLength: contextLength,
      maxOutputTokens: maxOutputTokens,
      known: known,
    );
  }

  /// Capabilities when nothing better is known. Every Anthropic model is
  /// [HistoryPolicy.appendOnly]: preserved thinking binds replayed blocks
  /// to the exact prefix, and prompt caching rewards append-only anyway.
  ModelCapabilities toCapabilities({int? contextLength, int? maxOutputTokens, bool? vision, ReasoningSupport? reasoning}) =>
      ModelCapabilities(
        contextLength: contextLength ?? this.contextLength,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        toolCallFormat: ToolCallFormat.native,
        parallelToolCalls: true,
        vision: vision ?? true,
        reasoning: reasoning ?? reasoningSupport,
        tokenizerFamily: 'claude',
        supportsSystemRole: true,
        supportsPromptCache: true,
        historyPolicy: HistoryPolicy.appendOnly,
      );

  /// Ids we know are current (R10 §7.11, claude-api skill 2026-10-06).
  /// Used when `/v1/models` is unreachable. Mythos is invitation-only and
  /// deliberately absent.
  static const List<(String, String)> currentModels = [
    ('claude-opus-5-5', 'Claude Opus 5.5'),
    ('claude-sonnet-5-5', 'Claude Sonnet 5.5'),
    ('claude-haiku-5-5', 'Claude Haiku 5.5'),
    ('claude-fable-5-1', 'Claude Fable 5.1'),
    ('claude-fable-5', 'Claude Fable 5'),
    ('claude-opus-5', 'Claude Opus 5'),
    ('claude-sonnet-5', 'Claude Sonnet 5'),
    ('claude-opus-4-8', 'Claude Opus 4.8'),
    ('claude-opus-4-7', 'Claude Opus 4.7'),
    ('claude-opus-4-6', 'Claude Opus 4.6'),
    ('claude-sonnet-4-6', 'Claude Sonnet 4.6'),
    ('claude-haiku-4-5', 'Claude Haiku 4.5'),
  ];
}

/// Dotted model version (`opus-5-5` → 5.5) with ordering.
@immutable
final class _Version implements Comparable<_Version> {
  const _Version(this.major, this.minor);
  final int major;
  final int minor;

  @override
  int compareTo(_Version o) => major != o.major ? major - o.major : minor - o.minor;

  bool operator >=(_Version o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) => other is _Version && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);
}

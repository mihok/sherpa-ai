import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../services/inference/runner_extras.dart'
    show ModelSummarizer, remoteSummaryTimeout, withSummarizer;
import '../../../services/mcp/composer_sources.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../../mcp/state/mcp_providers.dart';
import 'frame_scheduler.dart';

// Seams the chat feature adds on top of the app's root providers
// (lib/state/providers.dart). Each has a production default, so the
// integrator only overrides what it wants to change; tests override them
// with fakes.

/// Frame-aligned throttle for streamed deltas.
final chatFrameSchedulerProvider = Provider<FrameScheduler>((ref) => const SchedulerFrameScheduler());

/// Clipboard, share sheet and haptics behind one fakeable interface.
final chatPlatformProvider = Provider<ChatPlatformActions>((ref) => const DefaultChatPlatformActions());

/// Routes the chat navigates to. Override to match the shell's router.
final chatRoutesProvider = Provider<ChatRoutes>((ref) => const ChatRoutes());

/// Loop limits, retries and generation params for chat runs.
final chatAgentConfigProvider = Provider<AgentConfig>((ref) => const AgentConfig());

/// The context manager chat runs use. M3 replaces the passthrough with the
/// escalation ladder.
final chatContextManagerProvider = Provider<ContextManager>((ref) => const PassthroughContextManager());

/// Per-provider extras for the agent runner: an on-device provider supplies
/// an exact token counter and a context manager that warms it.
final class RunnerExtras {
  const RunnerExtras({this.counter, this.contextManager});
  final TokenCounter? counter;
  final ContextManager? contextManager;
}

typedef RunnerExtrasFor = RunnerExtras Function(ModelProvider provider, ModelChoice choice, ContextManager base);

/// The per-provider part: overridden by the on-device feature
/// (`localChatRunnerExtras`: the engine's counter, and summaries written by
/// the chat's own local model at background priority).
final chatRunnerExtrasProvider = Provider<RunnerExtrasFor>((ref) => (provider, choice, base) => const RunnerExtras());

/// What a chat's runner, its "Compact now" and the context inspector all
/// use, so the three never disagree about how a chat is counted and
/// summarized: [chatRunnerExtrasProvider] over [base], plus the user's
/// summary choice for every other provider ([UiSettings.modelSummaries]:
/// off = the base ladder's extractive summaries; on = the chat's own model
/// writes them, with the extractive one as fallback). The result always
/// names a context manager.
final chatContextExtrasProvider = Provider<RunnerExtrasFor>((ref) {
  final perProvider = ref.watch(chatRunnerExtrasProvider);
  final modelSummaries = ref.watch(uiSettingsProvider.select((s) => s.modelSummaries));
  final clock = ref.watch(clockProvider);
  return (provider, choice, base) {
    final remote = choice.providerId != localProviderId;
    final b = remote && modelSummaries
        ? withSummarizer(
            base,
            ModelSummarizer(provider: provider, modelId: choice.modelId, timeout: remoteSummaryTimeout),
            clock: clock,
          )
        : base;
    final e = perProvider(provider, choice, b);
    return RunnerExtras(counter: e.counter, contextManager: e.contextManager ?? b);
  };
});

/// How the runner waits between provider retries (null = real time).
/// Tests swap in an instant sleeper.
final chatRetrySleepProvider = Provider<Sleeper?>((ref) => null);

/// The MCP side of the composer: a prompt (slash command) expanded into
/// messages, an `@` mention resolved to a resource part. Defaults to the
/// app's MCP host ([mcpComposerSourcesProvider]); tests swap in fakes.
abstract interface class ChatMcpSources {
  Future<McpExpandedPrompt> expand(McpPromptCommand command, Map<String, String> arguments);

  Future<ContentPart> resolveMention(McpResourceSuggestion mention);
}

final chatMcpSourcesProvider = Provider<ChatMcpSources>(_HostMcpSources.new);

final class _HostMcpSources implements ChatMcpSources {
  _HostMcpSources(this._ref);

  final Ref _ref;

  @override
  Future<McpExpandedPrompt> expand(McpPromptCommand command, Map<String, String> arguments) =>
      _ref.read(mcpComposerSourcesProvider).expand(command, arguments);

  @override
  Future<ContentPart> resolveMention(McpResourceSuggestion mention) =>
      _ref.read(mcpComposerSourcesProvider).resolveMention(mention);
}

/// Paths the chat pushes with go_router.
@immutable
final class ChatRoutes {
  const ChatRoutes({
    this.newProvider = '/settings/providers/new',
    this.editProvider = _editProvider,
    this.chat = _chat,
    this.context = _context,
    this.handoff = _handoff,
    this.models = '/settings/models',
    this.tools = '/settings/tools',
  });

  /// Provider setup (the "no provider configured" call to action).
  final String newProvider;

  /// Settings for one provider ("Fix provider" on auth and billing errors).
  final String Function(String providerId) editProvider;

  /// A chat by session id (used by /new and "Start a new chat").
  final String Function(String sessionId) chat;

  /// The context inspector of a chat (context ring, overflow menu).
  final String Function(String sessionId) context;

  /// The handoff review of a chat ("Hand off…").
  final String Function(String sessionId) handoff;

  /// The on-device model library (local engine errors, "no models").
  final String models;

  /// Tools & servers ("Manage servers" in the chat's tools sheet).
  final String tools;

  static String _editProvider(String providerId) => '/settings/providers/${Uri.encodeComponent(providerId)}';
  static String _chat(String sessionId) => '/chat/${Uri.encodeComponent(sessionId)}';
  static String _context(String sessionId) => '${_chat(sessionId)}/context';
  static String _handoff(String sessionId) => '${_chat(sessionId)}/handoff';
}

/// Haptic moments, mapped per docs/research/12 §1.9. Never per token.
enum ChatHaptic { send, approvalRequested, toolFailed, runComplete, selection }

abstract interface class ChatPlatformActions {
  Future<void> copyText(String text);

  Future<void> shareText(String text, {String? subject});

  Future<void> haptic(ChatHaptic kind);
}

final class DefaultChatPlatformActions implements ChatPlatformActions {
  const DefaultChatPlatformActions();

  @override
  Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<void> shareText(String text, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  @override
  Future<void> haptic(ChatHaptic kind) => switch (kind) {
        ChatHaptic.send => HapticFeedback.lightImpact(),
        ChatHaptic.approvalRequested => HapticFeedback.warningNotification(),
        ChatHaptic.toolFailed => HapticFeedback.errorNotification(),
        ChatHaptic.runComplete => HapticFeedback.successNotification(),
        ChatHaptic.selection => HapticFeedback.selectionClick(),
      };
}

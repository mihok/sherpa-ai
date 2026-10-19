import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sherpa_core/sherpa_core.dart';

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

/// How the runner waits between provider retries (null = real time).
/// Tests swap in an instant sleeper.
final chatRetrySleepProvider = Provider<Sleeper?>((ref) => null);

/// Paths the chat pushes with go_router.
@immutable
final class ChatRoutes {
  const ChatRoutes({
    this.newProvider = '/settings/providers/new',
    this.editProvider = _editProvider,
    this.chat = _chat,
    this.context = _context,
    this.handoff = _handoff,
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

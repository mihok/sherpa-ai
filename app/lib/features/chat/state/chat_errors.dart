import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'model_selection.dart';

/// What went wrong, in terms of what the user can do about it.
enum ChatErrorKind {
  auth,
  rateLimited,
  overloaded,
  quotaExceeded,
  offline,
  timeout,
  contextOverflow,
  modelNotFound,
  localEngine,
  invalidRequest,
  server,
  needsUserAction,
  noProvider,
  needsModel,
  providerMissing,
  sessionMissing,
  unknown,
}

/// The buttons an error card can offer. The screen maps each to navigation
/// or a controller call; the controller never navigates itself.
///
/// [retry] ("Try again") repeats exactly what failed: the run that ended
/// with this error, or the action (share, copy, branch switch…) that threw.
/// The controller binds it to that operation (`ChatController.retryError`)
/// and drops it from errors with nothing to repeat.
enum ChatErrorAction { fixProvider, addProvider, retry, changeModel, newChat }

/// An error mapped to calm, specific copy and the actions that can fix it.
///
/// Rule: every error names its cause in plain words and offers a way
/// forward (the card can always be dismissed); "retry" is offered only
/// where retrying can help (never for a spending cap or a rejected key) and
/// only repeats what failed.
@immutable
final class ChatError {
  const ChatError({
    required this.kind,
    required this.title,
    required this.message,
    this.actions = const [],
    this.detail,
    this.providerId,
    this.retryAfter,
  });

  final ChatErrorKind kind;
  final String title;
  final String message;
  final List<ChatErrorAction> actions;

  /// Technical text (status code, server message) behind a "Details" toggle.
  final String? detail;
  final String? providerId;
  final Duration? retryAfter;

  ChatError withActions(List<ChatErrorAction> actions) => ChatError(
        kind: kind,
        title: title,
        message: message,
        actions: actions,
        detail: detail,
        providerId: providerId,
        retryAfter: retryAfter,
      );
}

/// Thrown by the controller when a run can't start for a setup reason.
final class ChatSetupException implements Exception {
  const ChatSetupException(this.kind, this.message);
  final ChatErrorKind kind;
  final String message;

  @override
  String toString() => 'ChatSetupException(${kind.name}): $message';
}

/// Maps whatever ended a run (or failed an action) to a [ChatError].
ChatError chatErrorFrom(
  Object? error, {
  RunOutcome? outcome,
  String? detail,
  ModelSelection? model,
}) {
  final provider = model?.providerName ?? 'The provider';
  final host = model?.host ?? model?.providerName ?? 'the server';
  final modelName = model?.modelName ?? 'this model';

  if (error is ChatSetupException) return _setupError(error);
  if (error is ContextOverflowException) return _overflow(modelName, error.message);
  if (error is ProviderException) {
    final tech = [
      if (error.statusCode != null) 'HTTP ${error.statusCode}',
      error.message,
    ].join(' · ');
    switch (error.kind) {
      case ProviderErrorKind.auth:
        return ChatError(
          kind: ChatErrorKind.auth,
          title: "$provider didn't accept the API key",
          message: 'Update the key in provider settings, or switch to another model.',
          actions: const [ChatErrorAction.fixProvider, ChatErrorAction.changeModel],
          detail: tech,
          providerId: model?.providerId ?? error.providerId,
        );
      case ProviderErrorKind.rateLimited:
        final wait = error.retryAfter;
        return ChatError(
          kind: ChatErrorKind.rateLimited,
          title: '$provider is limiting requests',
          message: wait == null
              ? 'Too many requests in a short time. Wait a moment, then try again.'
              : 'Too many requests in a short time. You can try again in ${_humanDuration(wait)}.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
          retryAfter: wait,
        );
      case ProviderErrorKind.overloaded:
        return ChatError(
          kind: ChatErrorKind.overloaded,
          title: '$provider is overloaded',
          message: 'This is usually brief. Try again in a moment, or switch to another model.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
          retryAfter: error.retryAfter,
        );
      case ProviderErrorKind.quotaExceeded:
        return ChatError(
          kind: ChatErrorKind.quotaExceeded,
          title: 'Your $provider account is out of credit',
          message: 'The provider reports a spending limit or exhausted quota. Add credit or raise the '
              "limit in your provider's billing settings, or switch to another model. Retrying won't help "
              'until then.',
          actions: const [ChatErrorAction.changeModel, ChatErrorAction.fixProvider],
          detail: tech,
          providerId: model?.providerId ?? error.providerId,
        );
      case ProviderErrorKind.network:
        return ChatError(
          kind: ChatErrorKind.offline,
          title: "Can't reach $host",
          message: 'Check your connection and try again. On-device models keep working offline.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
        );
      case ProviderErrorKind.timeout:
        return ChatError(
          kind: ChatErrorKind.timeout,
          title: '$provider took too long to answer',
          message: 'The connection may be slow, or the server is busy. Try again.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
        );
      case ProviderErrorKind.contextOverflow:
        return _overflow(modelName, tech);
      case ProviderErrorKind.modelNotFound:
        return ChatError(
          kind: ChatErrorKind.modelNotFound,
          title: "$modelName isn't available",
          message: "$provider doesn't offer this model (any more). Choose another one.",
          actions: const [ChatErrorAction.changeModel],
          detail: tech,
        );
      case ProviderErrorKind.outOfMemory || ProviderErrorKind.engineCrashed:
        return ChatError(
          kind: ChatErrorKind.localEngine,
          title: 'The on-device model stopped',
          message: error.kind == ProviderErrorKind.outOfMemory
              ? 'There was not enough free memory. Try a smaller model, or close other apps and retry.'
              : 'The local engine restarted. Your conversation is safe; try again.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
        );
      case ProviderErrorKind.invalidRequest || ProviderErrorKind.unsupported:
        return ChatError(
          kind: ChatErrorKind.invalidRequest,
          title: '$provider rejected the request',
          message: 'This model may not support something in this chat. Try again, or switch models.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
        );
      case ProviderErrorKind.server || ProviderErrorKind.unknown:
        return ChatError(
          kind: ChatErrorKind.server,
          title: '$provider had a problem',
          message: 'The server returned an error. Try again in a moment.',
          actions: const [ChatErrorAction.retry, ChatErrorAction.changeModel],
          detail: tech,
        );
    }
  }
  if (outcome == RunOutcome.needsUserAction) {
    return ChatError(
      kind: ChatErrorKind.needsUserAction,
      title: 'Sherpa needs your input to continue',
      message: detail ?? 'The run stopped before finishing.',
      actions: const [ChatErrorAction.newChat, ChatErrorAction.changeModel],
    );
  }
  if (error is StateError && error.message.startsWith('unknown session')) {
    return const ChatError(
      kind: ChatErrorKind.sessionMissing,
      title: 'This chat no longer exists',
      message: 'It may have been deleted on this device. Start a new chat.',
      actions: [ChatErrorAction.newChat],
    );
  }
  return ChatError(
    kind: ChatErrorKind.unknown,
    title: 'Something went wrong',
    message: 'Your conversation is saved. Try again.',
    actions: const [ChatErrorAction.retry],
    detail: detail ?? error?.toString(),
  );
}

/// Maps the failure of an action that is not a run (share, copy, branch
/// switch, model change, new chat…) to a [ChatError].
///
/// There is no reply to regenerate, so the run's "Try again" is never
/// implied: the card offers [actions], the ways forward that fit what
/// failed. [ChatErrorAction.retry] among them means "do [failed] again",
/// and the caller binds it to that action.
ChatError actionErrorFrom(
  Object error, {
  required String failed,
  List<ChatErrorAction> actions = const [ChatErrorAction.retry],
  ModelSelection? model,
}) {
  final mapped = chatErrorFrom(error, model: model);
  if (mapped.kind != ChatErrorKind.unknown) {
    // Setup and provider errors keep their own fixes; "retry" only when the
    // caller can repeat the action.
    return mapped.withActions([
      for (final a in mapped.actions)
        if (a != ChatErrorAction.retry || actions.contains(ChatErrorAction.retry)) a,
    ]);
  }
  return ChatError(
    kind: ChatErrorKind.unknown,
    title: "Couldn't $failed",
    message: actions.contains(ChatErrorAction.retry)
        ? 'Your conversation is saved. Try again.'
        : 'Your conversation is saved.',
    actions: actions,
    detail: error.toString(),
  );
}

ChatError _setupError(ChatSetupException e) => switch (e.kind) {
      ChatErrorKind.noProvider => ChatError(
          kind: e.kind,
          title: 'Add a model provider to start',
          message: e.message,
          actions: const [ChatErrorAction.addProvider],
        ),
      ChatErrorKind.providerMissing => ChatError(
          kind: e.kind,
          title: "This chat's provider is unavailable",
          message: e.message,
          actions: const [ChatErrorAction.changeModel, ChatErrorAction.addProvider],
        ),
      _ => ChatError(
          kind: e.kind,
          title: 'Choose a model to start',
          message: e.message,
          actions: const [ChatErrorAction.changeModel],
        ),
    };

ChatError _overflow(String modelName, String detail) => ChatError(
      kind: ChatErrorKind.contextOverflow,
      title: 'This chat is too long for $modelName',
      message: 'The conversation no longer fits its context window. Start a new chat, or switch to a '
          'model with a larger window.',
      actions: const [ChatErrorAction.newChat, ChatErrorAction.changeModel],
      detail: detail,
    );

String _humanDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds.clamp(1, 59)} s';
  final m = (d.inSeconds / 60).ceil();
  return '$m min';
}

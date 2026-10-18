import 'dart:async';

/// Thrown (or delivered as a stream error) when work is cancelled through a
/// [CancellationToken]. Callers distinguish it from failures so that a user
/// pressing "stop" is never reported as an error.
final class CancelledException implements Exception {
  const CancelledException([this.reason = 'cancelled']);

  final String reason;

  @override
  String toString() => 'CancelledException: $reason';
}

/// Cooperative cancellation shared by the agent loop, providers and tools.
///
/// Tokens form a tree: cancelling a parent cancels every child, so the
/// "stop everything" control only needs the root token of a run.
final class CancellationToken {
  CancellationToken({CancellationToken? parent}) : _parent = parent {
    if (parent != null) {
      if (parent.isCancelled) {
        _cancel(parent._reason ?? 'parent cancelled');
      } else {
        parent._children.add(this);
      }
    }
  }

  /// A token that is never cancelled.
  static final CancellationToken none = CancellationToken();

  final Completer<String> _completer = Completer<String>();
  final List<CancellationToken> _children = [];
  final CancellationToken? _parent;
  String? _reason;

  bool get isCancelled => _completer.isCompleted;
  String? get reason => _reason;

  /// Completes with the reason once cancelled; never errors.
  Future<String> get whenCancelled => _completer.future;

  CancellationToken child() => CancellationToken(parent: this);

  void cancel([String reason = 'cancelled']) => _cancel(reason);

  void _cancel(String reason) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete(reason);
    for (final c in List.of(_children)) {
      c._cancel(reason);
    }
    _children.clear();
  }

  /// Unlinks this token from its parent once the work it guarded is done,
  /// so a long-lived run token does not accumulate one child per request.
  void detach() => _parent?._children.remove(this);

  void throwIfCancelled() {
    if (isCancelled) throw CancelledException(_reason ?? 'cancelled');
  }
}

import 'package:meta/meta.dart';

import '../common/clock.dart';
import '../common/json.dart';
import '../model/tool.dart';

enum RiskLevel { safe, moderate, destructive }

enum ApprovalScope { once, session, always }

/// A remembered "always allow" grant with scope and expiry.
@immutable
final class ApprovalGrant {
  const ApprovalGrant({
    required this.toolName,
    required this.scope,
    required this.grantedAt,
    this.sessionId,
    this.expiresAt,
  });

  factory ApprovalGrant.fromJson(JsonMap j) => ApprovalGrant(
        toolName: j.req<String>('toolName'),
        scope: ApprovalScope.values.byName(j.req<String>('scope')),
        grantedAt: DateTime.parse(j.req<String>('grantedAt')),
        sessionId: j.opt<String>('sessionId'),
        expiresAt: j.optDate('expiresAt'),
      );

  final String toolName;
  final ApprovalScope scope;
  final DateTime grantedAt;
  final String? sessionId;
  final DateTime? expiresAt;

  bool covers(String tool, String session, DateTime now) {
    if (tool != toolName) return false;
    if (expiresAt != null && !now.isBefore(expiresAt!)) return false;
    return switch (scope) {
      ApprovalScope.once => false,
      ApprovalScope.session => sessionId == session,
      ApprovalScope.always => true,
    };
  }

  JsonMap toJson() => compact({
        'toolName': toolName,
        'scope': scope.name,
        'grantedAt': grantedAt.toUtc().toIso8601String(),
        'sessionId': sessionId,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
      });
}

sealed class ApprovalRequirement {
  const ApprovalRequirement();
}

final class AutoApprove extends ApprovalRequirement {
  const AutoApprove(this.reason);
  final String reason;
}

final class NeedsConfirmation extends ApprovalRequirement {
  const NeedsConfirmation(this.risk, this.reason);
  final RiskLevel risk;
  final String reason;
}

final class Denied extends ApprovalRequirement {
  const Denied(this.reason);
  final String reason;
}

enum UserDecision { approve, deny }

@immutable
final class ApprovalResponse {
  const ApprovalResponse(this.decision, {this.scope = ApprovalScope.once, this.expiresIn});
  final UserDecision decision;
  final ApprovalScope scope;
  final Duration? expiresIn;
}

/// Decides whether a call may run without asking. Annotations are hints
/// from possibly untrusted servers, so [trustedServers] gates whether
/// `readOnlyHint` alone is enough to auto-run.
final class ApprovalPolicy {
  ApprovalPolicy({
    Clock clock = const SystemClock(),
    Set<String> trustedServers = const {},
    List<ApprovalGrant> grants = const [],
    this.autoRunReadOnly = true,
  })  : _clock = clock, // ignore: prefer_initializing_formals
        _trusted = {...trustedServers},
        _grants = [...grants];

  final Clock _clock;
  final Set<String> _trusted;
  final List<ApprovalGrant> _grants;
  final bool autoRunReadOnly;

  List<ApprovalGrant> get grants => List.unmodifiable(_grants);

  static RiskLevel riskOf(ToolDefinition tool) {
    final a = tool.annotations;
    if (a.isReadOnly) return RiskLevel.safe;
    if (a.isDestructive) return RiskLevel.destructive;
    return RiskLevel.moderate;
  }

  ApprovalRequirement evaluate(ToolDefinition tool, String sessionId) {
    final now = _clock.now();
    final risk = riskOf(tool);
    if (_grants.any((g) => g.covers(tool.name, sessionId, now))) {
      return const AutoApprove('previously allowed');
    }
    final isBuiltin = tool.source.kind == ToolSourceKind.builtin;
    final trusted = isBuiltin || _trusted.contains(tool.source.serverId);
    if (risk == RiskLevel.safe && autoRunReadOnly && trusted) {
      return const AutoApprove('read-only tool from a trusted source');
    }
    if (risk == RiskLevel.safe && autoRunReadOnly && !tool.annotations.isOpenWorld) {
      return const AutoApprove('read-only, closed-world tool');
    }
    return NeedsConfirmation(
      risk,
      switch (risk) {
        RiskLevel.destructive => 'This action may modify or delete data.',
        RiskLevel.moderate => 'This action may change state outside the app.',
        RiskLevel.safe => 'This server is not trusted to self-declare read-only tools.',
      },
    );
  }

  void record(String toolName, String sessionId, ApprovalResponse response) {
    if (response.decision != UserDecision.approve) return;
    if (response.scope == ApprovalScope.once) return;
    final now = _clock.now();
    _grants.add(ApprovalGrant(
      toolName: toolName,
      scope: response.scope,
      grantedAt: now,
      sessionId: response.scope == ApprovalScope.session ? sessionId : null,
      expiresAt: response.expiresIn == null ? null : now.add(response.expiresIn!),
    ));
  }

  void revoke(String toolName) => _grants.removeWhere((g) => g.toolName == toolName);

  void trustServer(String serverId) => _trusted.add(serverId);
  void untrustServer(String serverId) => _trusted.remove(serverId);
}

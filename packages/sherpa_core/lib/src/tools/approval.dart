import 'package:meta/meta.dart';

import '../common/clock.dart';
import '../common/json.dart';
import '../model/tool.dart';

enum RiskLevel { safe, moderate, destructive }

enum ApprovalScope { once, session, always }

/// A remembered "always allow" grant with scope and expiry.
///
/// A grant is bound to the definition the user saw ([definitionHash], R11
/// §9.7: "always" is per server + tool + hash): when the tool's definition
/// changes, the grant no longer covers it. Grants persisted before hashes
/// existed have no hash and cover only tools without one.
@immutable
final class ApprovalGrant {
  const ApprovalGrant({
    required this.toolName,
    required this.scope,
    required this.grantedAt,
    this.sessionId,
    this.expiresAt,
    this.definitionHash,
  });

  factory ApprovalGrant.fromJson(JsonMap j) => ApprovalGrant(
        toolName: j.req<String>('toolName'),
        scope: ApprovalScope.values.byName(j.req<String>('scope')),
        grantedAt: DateTime.parse(j.req<String>('grantedAt')),
        sessionId: j.opt<String>('sessionId'),
        expiresAt: j.optDate('expiresAt'),
        definitionHash: j.opt<String>('definitionHash'),
      );

  final String toolName;
  final ApprovalScope scope;
  final DateTime grantedAt;
  final String? sessionId;
  final DateTime? expiresAt;

  /// `ToolDefinition.definitionHash` of the tool when it was granted.
  final String? definitionHash;

  /// Whether this grant lets a call to [tool] (with [definitionHash], the
  /// tool's current hash) in [session] skip the prompt at [now].
  bool covers(String tool, String session, DateTime now, {String? definitionHash}) {
    if (tool != toolName) return false;
    if (definitionHash != this.definitionHash) return false;
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
        'definitionHash': definitionHash,
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
  const NeedsConfirmation(this.risk, this.reason, {this.oneOffOnly = false});
  final RiskLevel risk;
  final String reason;

  /// Only a one-off answer is possible: no grant skipped this prompt and the
  /// answer is never remembered, whatever scope the handler returns. Set for
  /// a repaired or name-corrected call to a tool that is not read-only
  /// (R11 §9.6.7). An approval UI offers only "Deny" and "Allow once".
  final bool oneOffOnly;

  /// The scopes an approval UI may offer for "allow": once only for
  /// [oneOffOnly]; never "always" for a destructive tool (R11 §9.7).
  List<ApprovalScope> get allowedScopes => oneOffOnly
      ? const [ApprovalScope.once]
      : risk == RiskLevel.destructive
          ? const [ApprovalScope.once, ApprovalScope.session]
          : ApprovalScope.values;
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

/// Decides whether a call may run without asking.
///
/// Tool annotations are hints from possibly untrusted servers: MCP clients
/// MUST treat them as untrusted unless the server is trusted (R01 §6, R11
/// §9.7). Every decision here uses [annotationsFor]: the declared hints for
/// built-in tools and [trustedServers], the MCP worst case (destructive,
/// open-world, not idempotent) for every other tool. The declared hints of
/// an untrusted tool are for display only.
final class ApprovalPolicy {
  ApprovalPolicy({
    Clock clock = const SystemClock(),
    Set<String> trustedServers = const {},
    List<ApprovalGrant> grants = const [],
    this.autoRunReadOnly = true,
  })  : _clock = clock,
        _trusted = {...trustedServers},
        _grants = [...grants];

  final Clock _clock;
  final Set<String> _trusted;
  final List<ApprovalGrant> _grants;
  final bool autoRunReadOnly;

  List<ApprovalGrant> get grants => List.unmodifiable(_grants);

  /// The risk the tool's annotations DECLARE, trusted or not: display only.
  /// Decisions use [riskFor].
  static RiskLevel riskOf(ToolDefinition tool) => _riskOfAnnotations(tool.annotations);

  static RiskLevel _riskOfAnnotations(ToolAnnotations a) {
    if (a.isReadOnly) return RiskLevel.safe;
    if (a.isDestructive) return RiskLevel.destructive;
    return RiskLevel.moderate;
  }

  /// Built-in tools and tools of a server the user trusts.
  bool isTrusted(ToolDefinition tool) {
    if (tool.source.kind == ToolSourceKind.builtin) return true;
    final id = tool.source.serverId;
    return id != null && _trusted.contains(id);
  }

  /// The annotations decisions are based on: the declared ones when
  /// [isTrusted], [ToolAnnotations.untrustedDefaults] otherwise.
  ToolAnnotations annotationsFor(ToolDefinition tool) =>
      isTrusted(tool) ? tool.annotations : tool.annotations.untrustedDefaults;

  /// The risk decisions use (untrusted tools count as destructive).
  RiskLevel riskFor(ToolDefinition tool) => _riskOfAnnotations(annotationsFor(tool));

  /// Whether a call that was running when the process died may run again on
  /// resume without asking: only when its annotations are trusted and say
  /// read-only or idempotent (R11 §9.8).
  bool mayRerunInterrupted(ToolDefinition tool) => annotationsFor(tool).isIdempotent;

  Iterable<ApprovalGrant> _covering(ToolDefinition tool, String sessionId, DateTime now) =>
      _grants.where((g) => g.covers(tool.name, sessionId, now, definitionHash: tool.definitionHash));

  /// [tainted] is true once untrusted content (output of a non-built-in
  /// tool, an MCP resource…) is in the session's context. Then the "Rule of
  /// Two" applies (docs/research/11 §9.7): untrusted input must not drive a
  /// state-changing or open-world action without a human in the loop, so
  /// only an explicit "always allow" grant can skip the prompt, and read-only
  /// auto-approval no longer covers open-world tools (a read-only fetch can
  /// still exfiltrate through its arguments).
  ///
  /// [repaired] (the model's arguments had to be repaired) and
  /// [nameCorrected] (the tool name was normalized or fuzzy-matched) force a
  /// one-off confirmation for any tool that is not read-only, whatever the
  /// grants say (R11 §9.6.7). A tool with
  /// `ToolDefinition.requiresConfirmation` always asks unless the user
  /// granted its exact definition.
  ApprovalRequirement evaluate(
    ToolDefinition tool,
    String sessionId, {
    bool tainted = false,
    bool repaired = false,
    bool nameCorrected = false,
  }) {
    final now = _clock.now();
    final trusted = isTrusted(tool);
    final a = annotationsFor(tool);
    final risk = _riskOfAnnotations(a);
    if ((repaired || nameCorrected) && !a.isReadOnly) {
      return NeedsConfirmation(
        risk,
        nameCorrected
            ? 'The model asked for a tool by a slightly different name, and Sherpa matched it to this one. '
                'Check that this is the right tool and arguments; this can only be allowed once.'
            : 'The model sent malformed arguments for this call and Sherpa repaired them, so they may not be '
                'what it meant. Check them before allowing; this can only be allowed once.',
        oneOffOnly: true,
      );
    }
    final grants = _covering(tool, sessionId, now);
    if (tool.requiresConfirmation && (tool.definitionHash == null || grants.isEmpty)) {
      return NeedsConfirmation(
        risk == RiskLevel.safe ? RiskLevel.moderate : risk,
        'Sherpa flagged this tool\'s description as suspicious, so every call needs your approval.',
      );
    }
    final sensitive = !a.isReadOnly || a.isOpenWorld;
    if (tainted && sensitive && tool.source.kind != ToolSourceKind.builtin) {
      if (grants.any((g) => g.scope == ApprovalScope.always)) {
        return const AutoApprove('always allowed');
      }
      return NeedsConfirmation(
        risk == RiskLevel.safe ? RiskLevel.moderate : risk,
        'Untrusted content is in this conversation, so actions that change data or reach the internet '
        'need your approval.',
      );
    }
    if (grants.isNotEmpty) {
      return const AutoApprove('previously allowed');
    }
    // Only trusted annotations can say read-only, so this never auto-runs a
    // tool on a server's own say-so.
    if (risk == RiskLevel.safe && autoRunReadOnly) {
      return const AutoApprove('read-only tool from a trusted source');
    }
    return NeedsConfirmation(
      risk,
      !trusted
          ? 'This server is not trusted, so Sherpa does not rely on what it says about its tools and treats '
              'this action as one that may change or delete data.'
          : switch (risk) {
              RiskLevel.destructive => 'This action may modify or delete data.',
              RiskLevel.moderate => 'This action may change state outside the app.',
              RiskLevel.safe => 'This action only reads data.',
            },
    );
  }

  void record(String toolName, String sessionId, ApprovalResponse response, {String? definitionHash}) {
    if (response.decision != UserDecision.approve) return;
    if (response.scope == ApprovalScope.once) return;
    final now = _clock.now();
    _grants.add(ApprovalGrant(
      toolName: toolName,
      scope: response.scope,
      grantedAt: now,
      sessionId: response.scope == ApprovalScope.session ? sessionId : null,
      expiresAt: response.expiresIn == null ? null : now.add(response.expiresIn!),
      definitionHash: definitionHash,
    ));
  }

  /// Like [record], bound to [tool]'s current definition, but never stores
  /// an "always" grant for a destructive tool (untrusted tools count as
  /// destructive): those are downgraded to the session (docs/research/11
  /// §9.7). Records nothing when [requirement] was a one-off prompt
  /// ([NeedsConfirmation.oneOffOnly]).
  void recordFor(
    ToolDefinition tool,
    String sessionId,
    ApprovalResponse response, {
    ApprovalRequirement? requirement,
  }) {
    if (requirement is NeedsConfirmation && requirement.oneOffOnly) return;
    final downgrade = response.scope == ApprovalScope.always && riskFor(tool) == RiskLevel.destructive;
    record(
      tool.name,
      sessionId,
      downgrade ? ApprovalResponse(response.decision, scope: ApprovalScope.session) : response,
      definitionHash: tool.definitionHash,
    );
  }

  void revoke(String toolName) => _grants.removeWhere((g) => g.toolName == toolName);

  void trustServer(String serverId) => _trusted.add(serverId);
  void untrustServer(String serverId) => _trusted.remove(serverId);
}

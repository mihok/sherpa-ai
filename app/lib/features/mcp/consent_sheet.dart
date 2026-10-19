import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_auth/sherpa_auth.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../services/mcp/auth/mcp_oauth.dart';
import '../../state/ui_preferences.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// What the consent sheet shows before any OAuth authorization (MCP server
/// or Hugging Face): who asks, which site the user will sign in at (RFC
/// 9728 §7.8: show the authorization server, phishing happens there), the
/// permissions requested and what happens next.
final class OAuthConsentDetails {
  const OAuthConsentDetails({
    required this.title,
    required this.serverLabel,
    required this.authorizationOrigin,
    required this.scopes,
    required this.steps,
    this.serverHost,
    this.intro,
    this.warnings = const [],
    this.selfDescribedName,
  });

  /// From an [McpConsentRequest] for a configured server.
  factory OAuthConsentDetails.forMcp(McpConsentRequest r, {required String serverName}) {
    final asOrigin = r.authorizationServer.authorizationEndpoint.origin;
    final serverHost = r.serverHost;
    final asHost = r.authorizationServerHost;
    final otherSite = !_sameSite(serverHost, asHost);
    return OAuthConsentDetails(
      title: switch (r.purpose) {
        AuthPurpose.initial => 'Sign in to $serverName',
        AuthPurpose.reauthorize => 'Sign in to $serverName again',
        AuthPurpose.stepUp => '$serverName asks for more access',
      },
      intro: switch (r.purpose) {
        AuthPurpose.initial => 'This tool server needs you to sign in before Sherpa can use it.',
        AuthPurpose.reauthorize => 'The earlier sign-in expired or was revoked.',
        AuthPurpose.stepUp => r.operation == null
            ? 'A tool needs permissions you have not granted yet.'
            : 'The tool request "${r.operation}" needs permissions you have not granted yet.',
      },
      serverLabel: serverName,
      serverHost: serverHost,
      authorizationOrigin: asOrigin,
      scopes: r.scopes,
      selfDescribedName: r.resourceName,
      warnings: [
        if (otherSite) 'You will sign in at $asHost, a different site from the server ($serverHost). Make sure you trust it.',
        if (r.pkceOverrideInEffect)
          "This sign-in server doesn't advertise PKCE protection; you allowed it for this server. Sherpa still uses PKCE.",
      ],
      steps: [
        'Sherpa opens $asHost in a secure browser window. Sherpa cannot see what you type there.',
        'After you sign in, Sherpa receives a token for $serverHost only and keeps it in this phone\'s secure storage.',
        'You can sign out any time in Tools & servers; that deletes the token.',
      ],
    );
  }

  final String title;
  final String? intro;
  final String serverLabel;
  final String? serverHost;

  /// Where the user signs in (`https://auth.example.com`).
  final String authorizationOrigin;
  final List<String> scopes;
  final List<String> steps;
  final List<String> warnings;

  /// The server's own name for itself (untrusted, shown as such).
  final String? selfDescribedName;

  static bool _sameSite(String a, String b) {
    String site(String h) {
      final parts = h.toLowerCase().split('.');
      return parts.length <= 2 ? parts.join('.') : parts.sublist(parts.length - 2).join('.');
    }

    return site(a) == site(b);
  }
}

/// Plain words for well-known scopes; anything else is shown raw.
String describeScope(String scope) => switch (scope) {
      'openid' => 'Confirm who you are',
      'profile' => 'Your name and profile picture',
      'email' => 'Your email address',
      'offline_access' => 'Stay signed in (refresh the sign-in without asking)',
      'gated-repos' => 'Download gated models whose terms you accepted',
      'inference-api' => 'Use Inference Providers on your account (this can spend your credits)',
      'read-repos' => 'Read your repositories',
      'write-repos' => 'Change your repositories',
      _ => scope,
    };

/// Shows the consent sheet; true when the user chose to continue.
Future<bool> showOAuthConsentSheet(BuildContext context, OAuthConsentDetails details) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    sheetAnimationStyle: motionStyleOf(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => OAuthConsentSheet(details: details),
  );
  return ok ?? false;
}

class OAuthConsentSheet extends StatelessWidget {
  const OAuthConsentSheet({super.key, required this.details});

  final OAuthConsentDetails details;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final d = details;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, t.space.xl),
        children: [
          Heading(level: 2, child: Text(d.title, style: theme.textTheme.titleLarge)),
          if (d.intro != null) ...[SizedBox(height: t.space.sm), Text(d.intro!, style: muted)],
          SizedBox(height: t.space.lg),
          _Fact(label: 'Server', value: d.serverHost == null ? d.serverLabel : '${d.serverLabel} · ${d.serverHost}'),
          _Fact(label: 'You sign in at', value: d.authorizationOrigin, emphasize: true),
          if (d.selfDescribedName != null) _Fact(label: 'The server calls itself', value: '"${d.selfDescribedName}" (not verified)'),
          SizedBox(height: t.space.md),
          Heading(level: 3, child: Text('Permissions requested', style: theme.textTheme.titleSmall)),
          SizedBox(height: t.space.xs),
          if (d.scopes.isEmpty)
            Text("None named: the sign-in server decides what to grant. You'll see it there.", style: muted)
          else
            for (final s in d.scopes)
              Padding(
                padding: EdgeInsets.symmetric(vertical: t.space.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ExcludeSemantics(child: Icon(Icons.check_rounded, size: 18)),
                    SizedBox(width: t.space.sm),
                    Expanded(
                      child: Text(describeScope(s) == s ? s : '${describeScope(s)} ($s)'),
                    ),
                  ],
                ),
              ),
          for (final w in d.warnings) ...[
            SizedBox(height: t.space.md),
            NoteBox(text: w, icon: Icons.warning_amber_rounded, tone: NoteTone.warning),
          ],
          SizedBox(height: t.space.md),
          Heading(level: 3, child: Text('What happens', style: theme.textTheme.titleSmall)),
          SizedBox(height: t.space.xs),
          for (final (i, s) in d.steps.indexed)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space.xxs),
              child: Text('${i + 1}. $s'),
            ),
          SizedBox(height: t.space.xl),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: t.space.sm,
            runSpacing: t.space.sm,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.open_in_browser_rounded),
                label: const Text('Continue to sign in'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Text(value, style: emphasize ? theme.textTheme.titleMedium : theme.textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

/// Signs in to an MCP server from a tap: discovery, the consent sheet,
/// then the browser; reports the outcome in a snackbar. Returns whether
/// the server is signed in now.
Future<bool> signInToMcpServer(BuildContext context, WidgetRef ref, String serverId) async {
  final rt = ref.read(mcpRuntimeProvider);
  final haptics = ref.read(hapticsProvider);
  final server = rt.server(serverId);
  if (server == null) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final consent = await rt.oauth.prepareConsent(serverId);
  if (consent == null) {
    haptics.error();
    messenger?.showSnackBar(SnackBar(content: Text(rt.oauth.stateOf(serverId).failure ?? "This server's sign-in could not be started.")));
    return false;
  }
  if (!context.mounted) return false;
  final ok = await showOAuthConsentSheet(context, OAuthConsentDetails.forMcp(consent, serverName: server.name));
  if (!ok) {
    rt.oauth.decline(serverId);
    return false;
  }
  final result = await rt.oauth.authorize(serverId, consent);
  switch (result) {
    case McpSignedIn():
      haptics.success();
      messenger?.showSnackBar(SnackBar(content: Text('Signed in to ${server.name}')));
      return true;
    case McpSignInFailed(:final message, :final cancelled):
      if (!cancelled) haptics.error();
      messenger?.showSnackBar(SnackBar(content: Text(message)));
      return false;
  }
}

/// [signInToMcpServer] without awaiting (button callbacks).
void startMcpSignIn(BuildContext context, WidgetRef ref, String serverId) => unawaited(signInToMcpServer(context, ref, serverId));

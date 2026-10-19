import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../../design/tokens.dart';
import '../../mcp/widgets/mcp_widgets.dart' show NoteBox, NoteTone;
import '../state/chat_dependencies.dart';
import '../widgets/chat_style.dart';

/// Schemes rendered as tappable links in replies. Everything else (
/// `javascript:`, `file:`, `intent:`, app schemes…) is plain text, and
/// [replyLinkKind] refuses it again before anything opens.
const Set<String> kReplyLinkSchemes = {'http', 'https', 'mailto'};

/// What a reply link opens.
enum ReplyLinkKind {
  /// A web page: Custom Tabs / SFSafariViewController when the platform
  /// has them, else the browser app. Never an in-app WebView.
  web,

  /// A new email in the mail app.
  email,
}

/// The kind of [uri], or null when Sherpa refuses to open it: only
/// `http(s)` with a host and `mailto` with an address are allowed.
ReplyLinkKind? replyLinkKind(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if ((scheme == 'https' || scheme == 'http') && uri.host.isNotEmpty) return ReplyLinkKind.web;
  if (scheme == 'mailto' && _recipients(uri).isNotEmpty) return ReplyLinkKind.email;
  return null;
}

/// Why [uri] was not opened (for a link [replyLinkKind] refuses).
String replyLinkRefusal(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final what = switch (scheme) {
    '' => "This link wasn't opened.",
    'http' || 'https' || 'mailto' => "This link is incomplete, so it wasn't opened.",
    _ => "Sherpa doesn't open “$scheme:” links.",
  };
  return '$what Only web links (http, https) and email links (mailto) in replies can be opened.';
}

/// The host as people read it: international names decoded (Dart keeps
/// them percent-encoded), lower case.
String displayHost(Uri uri) {
  try {
    return Uri.decodeComponent(uri.host).toLowerCase();
  } on FormatException {
    return uri.host.toLowerCase();
  }
}

List<String> _recipients(Uri uri) =>
    uri.path.split(',').map((s) => Uri.decodeComponent(s).trim()).where((s) => s.contains('@')).toList();

bool _looksIdn(String host) =>
    host.split('.').any((l) => l.startsWith('xn--')) || host.contains('%') || host.runes.any((r) => r > 0x7f);

bool _looksIp(String host) =>
    host.contains(':') || // IPv6
    RegExp(r'^((0x[0-9a-f]*|\d+)\.?){1,4}$').hasMatch(host); // dotted, decimal, hex or octal IPv4

/// Things to check before opening [uri], in plain words (empty when
/// nothing stands out). Model-written links are untrusted: the text of a
/// link can name one site while the address goes to another.
List<String> replyLinkWarnings(Uri uri) {
  switch (replyLinkKind(uri)) {
    case ReplyLinkKind.web:
      final host = uri.host.toLowerCase();
      return [
        if (uri.scheme.toLowerCase() != 'https')
          'This page is not encrypted (http). Anyone on the network could see or change it.',
        if (_looksIdn(host))
          'The address uses international characters (${displayHost(uri)}). Look closely: it may imitate a site you know.',
        if (uri.userInfo.isNotEmpty)
          'The address has a user name before the site (“${uri.userInfo.split(':').first}@”). '
              'That is a common trick to make a link look like another site.',
        if (_looksIp(host)) 'The address is a bare IP address, not a site name.',
      ];
    case ReplyLinkKind.email:
      final q = uri.queryParameters.map((k, v) => MapEntry(k.toLowerCase(), v));
      final to = _recipients(uri);
      return [
        if (to.any((a) => _looksIdn(a.split('@').last)))
          'The email address uses international characters. Look closely: it may imitate an address you know.',
        if (to.length > 1 || q.containsKey('cc') || q.containsKey('bcc')) 'The email goes to more than one address.',
        if (q.containsKey('body') || q.containsKey('subject'))
          'The link also fills in the subject or text of the email. Read it before you send it.',
      ];
    case null:
      return const [];
  }
}

/// Opens confirmed reply links outside the app.
abstract interface class ChatLinkLauncher {
  /// False when nothing could open [uri].
  Future<bool> open(Uri uri, ReplyLinkKind kind);
}

/// [ChatLinkLauncher] over url_launcher.
///
/// Web links use `inAppBrowserView` (Custom Tabs / SFSafariViewController:
/// the app and the model can't see the page) only when the platform
/// reports support: on Android that mode otherwise falls back to an in-app
/// WebView, which Sherpa never uses for untrusted pages. Then the browser
/// app opens it. Email links open the mail app.
final class UrlLauncherChatLinks implements ChatLinkLauncher {
  const UrlLauncherChatLinks();

  @override
  Future<bool> open(Uri uri, ReplyLinkKind kind) async {
    if (replyLinkKind(uri) != kind) return false;
    try {
      final mode = switch (kind) {
        ReplyLinkKind.web =>
          await launcher.supportsLaunchMode(launcher.LaunchMode.inAppBrowserView)
              ? launcher.LaunchMode.inAppBrowserView
              : launcher.LaunchMode.externalApplication,
        ReplyLinkKind.email => launcher.LaunchMode.externalApplication,
      };
      return await launcher.launchUrl(uri, mode: mode);
    } on Object {
      return false;
    }
  }
}

/// How the chat opens links from replies (tests record instead).
final chatLinkLauncherProvider = Provider<ChatLinkLauncher>((ref) => const UrlLauncherChatLinks());

/// What the user chose in [ReplyLinkSheet].
enum ReplyLinkChoice { open, copy }

/// Tap on a link in a reply: refuses other schemes, otherwise asks first
/// (full address, the site in large type, warnings) and opens only on
/// "Open". Nothing is fetched or prefetched before that.
Future<void> openReplyLink(BuildContext context, WidgetRef ref, Uri uri) async {
  final kind = replyLinkKind(uri);
  if (kind == null) {
    _toast(context, replyLinkRefusal(uri));
    return;
  }
  final choice = await ReplyLinkSheet.show(context, uri: uri, kind: kind);
  if (!context.mounted) return;
  switch (choice) {
    case ReplyLinkChoice.open:
      final ok = await ref.read(chatLinkLauncherProvider).open(uri, kind);
      if (!ok && context.mounted) {
        _toast(
          context,
          kind == ReplyLinkKind.email ? "Couldn't open an email app." : "Couldn't open a browser for this link.",
        );
      }
    case ReplyLinkChoice.copy:
      await copyReplyLink(context, ref, uri);
    case null:
      break;
  }
}

/// Long press on a link: copies the address (nothing opens).
Future<void> copyReplyLink(BuildContext context, WidgetRef ref, Uri uri) async {
  final platform = ref.read(chatPlatformProvider);
  try {
    await platform.copyText(uri.toString());
    unawaited(platform.haptic(ChatHaptic.selection));
    if (context.mounted) _toast(context, 'Link copied');
  } on Object {
    if (context.mounted) _toast(context, "Couldn't copy the link.");
  }
}

void _toast(BuildContext context, String message) => ScaffoldMessenger.maybeOf(context)
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));

/// "Open this link?": the site (or email address) large, the full address
/// selectable, warnings, and Copy / Cancel / Open.
class ReplyLinkSheet extends StatelessWidget {
  const ReplyLinkSheet({super.key, required this.uri, required this.kind});

  final Uri uri;
  final ReplyLinkKind kind;

  static Future<ReplyLinkChoice?> show(BuildContext context, {required Uri uri, required ReplyLinkKind kind}) =>
      showModalBottomSheet<ReplyLinkChoice>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => ReplyLinkSheet(uri: uri, kind: kind),
      );

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final email = kind == ReplyLinkKind.email;
    final site = email ? _recipients(uri).join(', ') : displayHost(uri);
    final warnings = replyLinkWarnings(uri);
    final full = uri.toString();
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            headingLevel: 2,
            child: Text(email ? 'Write an email?' : 'Open this link?', style: theme.textTheme.titleLarge),
          ),
          SizedBox(height: t.space.md),
          Text(
            email ? 'To' : 'Site',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Semantics(
            label: '${email ? 'To' : 'Site'}: $site',
            excludeSemantics: true,
            child: Text(site, key: const ValueKey('reply-link-site'), style: theme.textTheme.headlineSmall),
          ),
          SizedBox(height: t.space.sm),
          Text('Full address', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          SelectableText(
            full.length > 2000 ? '${full.substring(0, 2000)}…' : full,
            key: const ValueKey('reply-link-full'),
            style: chatMonoStyle(context),
          ),
          for (final w in warnings) ...[
            SizedBox(height: t.space.sm),
            NoteBox(text: w, tone: NoteTone.warning, icon: Icons.warning_amber_rounded),
          ],
          SizedBox(height: t.space.md),
          Text(
            email
                ? 'The model wrote this link. Nothing is sent until you send the email yourself.'
                : 'The model wrote this link, and it may come from a web page or tool. Nothing is loaded until you '
                      'choose Open; the page opens in a secure browser window outside Sherpa.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          SizedBox(height: t.space.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: t.space.sm,
            runSpacing: t.space.sm,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(ReplyLinkChoice.copy),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy link'),
              ),
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(ReplyLinkChoice.open),
                icon: Icon(email ? Icons.mail_outline_rounded : Icons.open_in_browser_rounded),
                label: Text(email ? 'Write email' : 'Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

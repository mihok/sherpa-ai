import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/section_header.dart';
import '../../state/ui_preferences.dart';
import '../providers/fields.dart';
import '../settings/settings_page.dart';
import 'state/hub_account.dart';
import 'state/models_providers.dart';

/// Settings › Hugging Face account: paste a token, verify it, sign out.
///
/// A token unlocks gated models whose terms the user accepted and doubles
/// the anonymous rate limits, which matters on shared mobile networks
/// (R08 §6: one throttle was observed far below the documented quota from
/// a shared IP). OAuth sign-in is a later step (R08 §8.3); a pasted
/// fine-grained or read token is the documented fallback.
class HuggingFaceAccountScreen extends ConsumerStatefulWidget {
  const HuggingFaceAccountScreen({super.key});

  @override
  ConsumerState<HuggingFaceAccountScreen> createState() => _HuggingFaceAccountScreenState();
}

class _HuggingFaceAccountScreenState extends ConsumerState<HuggingFaceAccountScreen> {
  final TextEditingController _token = TextEditingController();
  String? _error;
  bool _busy = false;

  static const _tokensUrl = 'https://huggingface.co/settings/tokens';

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final haptics = ref.read(hapticsProvider);
    try {
      final p = await ref.read(hubAccountProvider).signIn(_token.text);
      if (!mounted) return;
      _token.clear();
      haptics.success();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Signed in as ${p.name}')));
    } on HubSignInException catch (e) {
      haptics.error();
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of Hugging Face?'),
        content: const Text('The token is deleted from this phone. Downloads of gated models will stop working '
            'until you add a token again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok ?? false) await ref.read(hubAccountProvider).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final profile = ref.watch(hubProfileProvider);
    final p = profile.value;
    final children = <Widget>[];
    if (profile.isLoading && p == null) {
      children.add(const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())));
    } else if (p != null) {
      children.addAll([
        const SectionHeader('Signed in'),
        ListTile(
          leading: CircleAvatar(child: Text(p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase())),
          title: Text(p.fullName?.isNotEmpty ?? false ? p.fullName! : p.name),
          subtitle: Text([
            '@${p.name}',
            p.tokenRoleLabel,
            if (p.isPro ?? false) 'PRO',
            if (p.orgs.isNotEmpty) 'Member of ${p.orgs.join(', ')}',
          ].join(' · ')),
        ),
        SettingsPadding(
          child: Text(
            'Sherpa sends this token to huggingface.co only, never to download mirrors or any other server. '
            'It is kept in the $secureStoreName.',
            style: muted,
          ),
        ),
        SizedBox(height: t.space.md),
        ListTile(
          leading: const Icon(Icons.logout_rounded),
          title: const Text('Sign out'),
          subtitle: const Text('Delete the token from this phone'),
          onTap: () => unawaited(_signOut()),
        ),
      ]);
    } else {
      children.addAll([
        SettingsPadding(
          child: Padding(
            padding: EdgeInsets.only(top: t.space.lg),
            child: Text(
              'Add a Hugging Face access token to download gated models whose terms you accepted on '
              'huggingface.co, and to get higher rate limits on shared networks.',
              style: muted,
            ),
          ),
        ),
        const SectionHeader('Access token'),
        SettingsPadding(
          child: ApiKeyField(
            controller: _token,
            label: 'Access token',
            hint: 'A "read" token is enough. Create one under huggingface.co › Settings › Access Tokens.',
            errorText: _error,
            onSubmitted: (_) => unawaited(_save()),
          ),
        ),
        SizedBox(height: t.space.md),
        SettingsPadding(
          child: Wrap(
            spacing: t.space.sm,
            runSpacing: t.space.sm,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_save()),
                icon: _busy
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_user_outlined),
                label: Text(_busy ? 'Checking with Hugging Face…' : 'Verify and save'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(const ClipboardData(text: _tokensUrl));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                  }
                },
                icon: const Icon(Icons.link_rounded),
                label: const Text('Copy token page link'),
              ),
            ],
          ),
        ),
        SizedBox(height: t.space.md),
        SettingsPadding(
          child: Text(
            'The token is checked with Hugging Face before it is saved, then kept in the $secureStoreName. '
            'It is only ever sent to huggingface.co.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]);
    }
    return SettingsPage(title: 'Hugging Face account', children: children);
  }
}

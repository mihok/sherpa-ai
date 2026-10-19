import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart' show UrlPolicyViolation;
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../state/provider_location.dart';
import '../../state/providers.dart';
import '../../state/ui_preferences.dart';
import '../providers/connection.dart';
import '../providers/fields.dart';
import '../providers/presets.dart';
import '../providers/provider_validation.dart';
import 'onboarding_scaffold.dart';

/// Step 2: the few fields this preset needs, then "Connect", which saves the
/// provider, probes it and fetches its models in one go.
class ConnectStep extends ConsumerStatefulWidget {
  const ConnectStep({super.key, required this.preset, required this.onResult, this.existing});

  final ProviderPreset preset;

  /// Provider saved by an earlier attempt in this flow (updated, not
  /// duplicated, when the user retries).
  final ProviderConfig? existing;

  /// Every attempt, failed or not: the provider is saved either way, so the
  /// parent can pass it back as [existing] and discard it if abandoned.
  final ValueChanged<ConnectionResult> onResult;

  @override
  ConsumerState<ConnectStep> createState() => _ConnectStepState();
}

class _ConnectStepState extends ConsumerState<ConnectStep> {
  late final TextEditingController _url =
      TextEditingController(text: widget.existing?.baseUrl.toString() ?? widget.preset.baseUrl ?? '');
  final TextEditingController _key = TextEditingController();
  late bool _allowLocal = widget.existing?.allowLocalNetwork ?? false;
  late bool _editUrl = widget.preset.baseUrl == null;
  String? _urlError;
  String? _keyError;
  bool _busy = false;
  ConnectionResult? _failure;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final preset = widget.preset;
    final check = checkBaseUrl(_url.text, allowLocalNetwork: _allowLocal);
    final key = _key.text.trim();
    setState(() {
      _failure = null;
      _urlError = check is BaseUrlError ? check.message : null;
      _keyError = preset.key == KeyRequirement.required && key.isEmpty && widget.existing == null
          ? 'Paste your ${preset.keyLabel.toLowerCase()} to continue.'
          : null;
      if (_urlError != null) _editUrl = true;
    });
    if (check is! BaseUrlOk || _keyError != null) return;

    final registry = ref.read(providerRegistryProvider);
    final config = ProviderConfig(
      id: widget.existing?.id ?? uniqueProviderId(preset.id, registry.configs.map((c) => c.id)),
      flavor: preset.flavor,
      profile: preset.profile,
      displayName: widget.existing?.displayName ?? preset.name,
      baseUrl: check.uri,
      allowLocalNetwork: _allowLocal,
    );
    setState(() => _busy = true);
    // DNS first: a plain-http name behind "my own network" must resolve to
    // a local address before the key is stored or sent anywhere.
    final verified = await verifyBaseUrl(
      check.uri,
      allowLocalNetwork: _allowLocal,
      resolver: ref.read(hostResolverProvider),
    );
    if (!mounted) return;
    if (verified is BaseUrlError) {
      _refuseUrl(verified.message);
      return;
    }
    final ConnectionResult result;
    try {
      result = await saveAndProbe(registry, config, apiKey: key.isEmpty ? null : key);
    } on UrlPolicyViolation catch (v) {
      // The registry's own check.
      if (mounted) _refuseUrl(explainUrlViolation(v, allowLocalNetwork: _allowLocal).message);
      return;
    } on Object {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text("Couldn't save the provider. Try again.")));
      }
      return;
    }
    if (!mounted) return;
    final haptics = ref.read(hapticsProvider);
    if (result.ok) {
      haptics.success();
      // Don't keep the key around in a controller longer than needed.
      _key.clear();
      setState(() => _busy = false);
    } else {
      haptics.error();
      setState(() {
        _busy = false;
        _failure = result;
      });
    }
    widget.onResult(result);
  }

  void _refuseUrl(String message) {
    ref.read(hapticsProvider).error();
    setState(() {
      _busy = false;
      _urlError = message;
      _editUrl = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final preset = widget.preset;
    final parsed = Uri.tryParse(_url.text.trim());
    final host = parsed != null && parsed.host.isNotEmpty ? hostLabel(parsed) : null;
    final failure = _failure;
    ref.watch(localHostVerdictsProvider); // the badge follows DNS verification
    return OnboardingStepLayout(
      title: 'Connect ${preset.name}',
      lead: preset.blurb,
      actions: [
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_connect()),
          icon: _busy ? const ButtonSpinner() : const Icon(Icons.link),
          label: Text(_busy ? 'Connecting…' : 'Connect'),
        ),
      ],
      children: [
        if (!_editUrl && host != null) ...[
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: t.space.sm,
                  runSpacing: t.space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Connects to', style: theme.textTheme.bodyMedium),
                    PrivacyBadge(location: _location(), host: _badgeHost() ?? host),
                  ],
                ),
              ),
              TextButton(onPressed: () => setState(() => _editUrl = true), child: const Text('Change')),
            ],
          ),
          SizedBox(height: t.space.lg),
        ] else ...[
          BaseUrlField(
            controller: _url,
            hint: preset.urlHint,
            errorText: _urlError,
            helperText: preset.isLocalServer ? "Use the computer's address on your Wi-Fi, not localhost." : null,
            onChanged: (_) => setState(() => _urlError = null),
          ),
          if (preset.isLocalServer || preset.group == PresetGroup.custom)
            LocalNetworkToggle(
              value: _allowLocal,
              onChanged: (v) => setState(() {
                _allowLocal = v;
                _urlError = null;
              }),
            ),
          SizedBox(height: t.space.lg),
        ],
        ApiKeyField(
          controller: _key,
          label: preset.keyLabel,
          optional: preset.key == KeyRequirement.optional || widget.existing != null,
          hint: widget.existing != null ? 'Leave empty to keep the saved key.' : preset.keyHint,
          errorText: _keyError,
          onChanged: (_) {
            if (_keyError != null) setState(() => _keyError = null);
          },
          onSubmitted: (_) => unawaited(_connect()),
        ),
        SizedBox(height: t.space.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 18, color: t.semantic.onDevice),
            SizedBox(width: t.space.sm),
            Expanded(
              child: Text(
                'Saved in the $secureStoreName on this phone and sent only to ${host ?? 'this server'}.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        if (failure != null) ...[
          SizedBox(height: t.space.xl),
          _FailureCard(result: failure, preset: preset),
        ],
      ],
    );
  }

  ProviderConfig? _draftConfig() {
    final parsed = Uri.tryParse(_url.text.trim());
    if (parsed == null || parsed.host.isEmpty) return null;
    return ProviderConfig(
      id: '_',
      flavor: widget.preset.flavor,
      displayName: '_',
      baseUrl: parsed,
      allowLocalNetwork: _allowLocal,
    );
  }

  ExecutionLocation _location() {
    final config = _draftConfig();
    if (config == null) {
      return widget.preset.isLocalServer ? ExecutionLocation.localNetwork : ExecutionLocation.remote;
    }
    return locationOf(config);
  }

  /// "host (unverified)" until DNS confirmed an opt-in host name is local.
  String? _badgeHost() {
    final config = _draftConfig();
    return config == null ? null : privacyHostLabel(config);
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.result, required this.preset});

  final ConnectionResult result;
  final ProviderPreset preset;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = explainStatus(result.status, host: hostLabel(result.config.baseUrl), preset: preset);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
              SizedBox(width: t.space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text.title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer)),
                    SizedBox(height: t.space.xs),
                    Text(text.message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

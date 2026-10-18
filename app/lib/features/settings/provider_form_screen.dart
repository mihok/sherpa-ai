import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/haptics.dart';
import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/provider_location.dart';
import '../../state/providers.dart';
import '../../state/services.dart';
import '../../state/ui_preferences.dart';
import '../providers/connection.dart';
import '../providers/fields.dart';
import '../providers/preset_picker.dart';
import '../providers/presets.dart';
import '../providers/provider_validation.dart';
import 'headers_editor.dart';
import 'provider_form_sections.dart';
import 'settings_page.dart';

/// Add (`providerId == null`) or edit a provider.
///
/// Testing a *new* provider has to save it (the registry only probes saved
/// providers); if the user then leaves without saving, that provisional
/// entry is removed again. Testing an *edited* provider with pending changes
/// says so on the button ("Save & test").
class ProviderFormScreen extends ConsumerStatefulWidget {
  const ProviderFormScreen({super.key, this.providerId, this.presetId});

  final String? providerId;
  final String? presetId;

  @override
  ConsumerState<ProviderFormScreen> createState() => _ProviderFormScreenState();
}

class _ProviderFormScreenState extends ConsumerState<ProviderFormScreen> {
  late final ProviderRegistry _registry = ref.read(providerRegistryProvider);
  late final PreferencesStore _prefs = ref.read(preferencesProvider);

  ProviderConfig? _original;
  ProviderPreset? _preset;
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _key = TextEditingController();
  ApiFlavor _flavor = ApiFlavor.openAiChat;
  bool _allowLocal = false;
  List<HeaderRow> _headers = const [];

  bool _hasSavedKey = false;
  bool _replacingKey = false;
  bool _clearKey = false;

  /// Id of a new provider saved by "Test connection" but not yet by "Save".
  String? _provisionalId;
  bool _committed = false;
  bool _discarding = false;

  bool _testing = false;
  bool _saving = false;
  bool _submitted = false;
  ConnectionResult? _test;
  String? _defaultModelId;
  bool _useForNewChats = false;
  String _snapshot = '';

  bool get _isEdit => widget.providerId != null;
  String get _keyLabel => _preset?.keyLabel ?? 'API key';

  @override
  void initState() {
    super.initState();
    final id = widget.providerId;
    if (id != null) {
      _original = _registry.configs.where((c) => c.id == id).firstOrNull;
      final o = _original;
      if (o != null) {
        _preset = ProviderPresets.forConfig(o);
        _name.text = o.displayName;
        _url.text = o.baseUrl.toString();
        _flavor = o.flavor;
        _allowLocal = o.allowLocalNetwork;
        _headers = [for (final e in o.headers.entries) (name: e.key, value: e.value)];
        _defaultModelId = o.defaultModelId;
        _useForNewChats = _prefs.defaultModel?.providerId == o.id;
        unawaited(_registry.hasApiKey(o.id).then((has) {
          if (mounted) setState(() => _hasSavedKey = has);
        }));
      }
    } else {
      final p = ProviderPresets.byId(widget.presetId);
      if (p != null) _applyPreset(p);
    }
    _snapshot = _fingerprint();
  }

  void _applyPreset(ProviderPreset p) {
    _preset = p;
    _name.text = p.name;
    _url.text = p.baseUrl ?? '';
    _flavor = p.flavor;
    _allowLocal = false;
    _useForNewChats = _prefs.defaultModel == null;
  }

  @override
  void dispose() {
    final provisional = _provisionalId;
    if (provisional != null && !_committed) unawaited(_registry.remove(provisional));
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  String _fingerprint() => [
        _name.text,
        _url.text,
        _flavor.name,
        _allowLocal,
        for (final h in _headers) '${h.name}:${h.value}',
        _key.text.isNotEmpty,
        _clearKey,
        _defaultModelId,
        _useForNewChats,
      ].join('|');

  bool get _dirty => _fingerprint() != _snapshot || (_provisionalId != null && !_committed);

  // ---- validation -------------------------------------------------------

  BaseUrlCheck get _urlCheck => checkBaseUrl(_url.text, allowLocalNetwork: _allowLocal);

  List<HeaderRow> get _headerRows => meaningfulRows(_headers);

  bool get _headersValid =>
      validateHeaders(_headerRows, keyFieldLabel: _keyLabel).every((e) => e.name == null && e.value == null);

  bool get _keyMissing =>
      (_preset?.key ?? KeyRequirement.optional) == KeyRequirement.required &&
      _key.text.trim().isEmpty &&
      (!_hasSavedKey || _clearKey);

  String? get _nameError => _submitted && _name.text.trim().isEmpty ? 'Give it a name.' : null;

  ProviderConfig? _draft() {
    final check = _urlCheck;
    if (check is! BaseUrlOk || !_headersValid) return null;
    final p = _preset ?? ProviderPresets.custom;
    final id = _original?.id ??
        _provisionalId ??
        uniqueProviderId(p.id, _registry.configs.map((c) => c.id));
    return ProviderConfig(
      id: id,
      flavor: _flavor,
      displayName: _name.text.trim().isEmpty ? p.name : _name.text.trim(),
      baseUrl: check.uri,
      profile: _original?.profile ?? p.profile,
      headers: {for (final h in _headerRows) h.name.trim(): h.value.trim()},
      defaultModelId: _defaultModelId,
      allowLocalNetwork: _allowLocal,
      modelOverrides: _original?.modelOverrides ?? const {},
    );
  }

  String? get _newKey => _key.text.trim().isEmpty ? null : _key.text.trim();

  // ---- actions ----------------------------------------------------------

  Future<void> _testConnection() async {
    setState(() => _submitted = true);
    final draft = _draft();
    if (draft == null) {
      ref.read(hapticsProvider).error();
      return;
    }
    setState(() => _testing = true);
    final ConnectionResult result;
    try {
      if (_isEdit && !_dirty) {
        final status = await _registry.probe(draft.id);
        final models = status == EndpointStatus.ok ? await _registry.models(draft.id) : const <ModelDescriptor>[];
        result = ConnectionResult(config: _original!, status: status, models: models);
      } else {
        result = await saveAndProbe(_registry, draft, apiKey: _newKey, clearApiKey: _clearKey && _newKey == null);
        if (_isEdit) {
          // "Save & test" persisted the edits.
          _committed = true;
        } else {
          _provisionalId = draft.id;
        }
      }
    } on Object {
      if (mounted) setState(() => _testing = false);
      return;
    }
    if (!mounted) return;
    ref.invalidate(providerStatusProvider(draft.id));
    ref.read(hapticsProvider).outcome(ok: result.ok);
    setState(() {
      _testing = false;
      _test = result;
      if (_newKey != null) {
        // The key is in secure storage now; don't keep it in the field.
        _key.clear();
        _hasSavedKey = true;
        _replacingKey = false;
      }
      if (result.ok && _defaultModelId == null && result.models.length == 1) {
        _defaultModelId = result.models.single.id;
      }
      if (_isEdit) _snapshot = _fingerprint();
    });
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    final draft = _draft();
    if (draft == null || _keyMissing || _name.text.trim().isEmpty) {
      ref.read(hapticsProvider).error();
      return;
    }
    setState(() => _saving = true);
    try {
      final exists = _registry.configs.any((c) => c.id == draft.id);
      final clear = _clearKey && _newKey == null;
      if (exists) {
        await _registry.update(draft, apiKey: _newKey, clearApiKey: clear);
      } else {
        await _registry.add(draft, apiKey: _newKey);
      }
      _committed = true;
      final wasDefault = _prefs.defaultModel?.providerId == draft.id;
      final model = _defaultModelId;
      if (_useForNewChats && model != null) {
        await _prefs.setDefaultModel(ModelChoice(providerId: draft.id, modelId: model));
      } else if (wasDefault && !_useForNewChats) {
        await _prefs.setDefaultModel(null);
      }
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save. Try again.")));
      }
      return;
    }
    if (!mounted) return;
    ref.invalidate(providerStatusProvider(draft.id));
    ref.read(hapticsProvider).success();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${draft.displayName} saved')));
    _snapshot = _fingerprint();
    context.go(Routes.providers);
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(_isEdit ? 'Your edits to this provider are not saved.' : 'This provider will not be added.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Discard')),
        ],
      ),
    );
    if ((leave ?? false) && mounted) {
      // Let the pop through; dispose() removes a provisional provider.
      setState(() => _discarding = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  // ---- UI ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isEdit && _original == null) {
      return Scaffold(
        appBar: AppBar(),
        body: StateView(
          title: 'Provider not found',
          message: 'It may have been removed.',
          icon: Icons.dns_outlined,
          primaryAction: FilledButton(onPressed: () => context.go(Routes.providers), child: const Text('All providers')),
        ),
      );
    }
    final preset = _preset;
    if (preset == null) {
      return SettingsPage(
        title: 'Add a provider',
        children: [
          SettingsPadding(
            child: PresetPicker(
              showLocalTeaser: false,
              onSelected: (p) => setState(() {
                _applyPreset(p);
                _snapshot = _fingerprint();
              }),
            ),
          ),
        ],
      );
    }
    return PopScope(
      canPop: !_dirty || _discarding,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: _form(context, preset),
    );
  }

  Widget _form(BuildContext context, ProviderPreset preset) {
    final t = SherpaTokens.of(context);
    final check = _urlCheck;
    final urlError = _submitted || _url.text.isNotEmpty ? (check is BaseUrlError ? check.message : null) : null;
    final needsOptIn = check is BaseUrlError && check.needsLocalNetworkOptIn;
    final draftLocation = check is BaseUrlOk
        ? locationOf(ProviderConfig(
            id: '_',
            flavor: _flavor,
            displayName: '_',
            baseUrl: check.uri,
            allowLocalNetwork: _allowLocal,
          ))
        : null;
    final id = _original?.id ?? _provisionalId;
    final listed = id == null ? null : ref.watch(providerModelsProvider(id)).value;
    final models = _test?.ok ?? false ? _test!.models : (_isEdit ? listed : null);
    final showKeyField = !_hasSavedKey || _replacingKey || _clearKey;

    return SettingsPage(
      title: _isEdit ? _original!.displayName : 'Add ${preset.name}',
      actions: [
        TextButton(onPressed: _saving ? null : () => unawaited(_save()), child: const Text('Save')),
      ],
      bottom: FilledButton(
        onPressed: _saving ? null : () => unawaited(_save()),
        child: Text(_saving ? 'Saving…' : 'Save'),
      ),
      children: [
        const SectionHeader('Connection'),
        SettingsPadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: 'Name', errorText: _nameError),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: t.space.lg),
              BaseUrlField(
                controller: _url,
                hint: preset.urlHint,
                errorText: urlError,
                onChanged: (_) => setState(() => _test = null),
              ),
              if (draftLocation != null) ...[
                SizedBox(height: t.space.sm),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PrivacyBadge(location: draftLocation, host: hostLabel((check as BaseUrlOk).uri)),
                ),
              ],
              if (preset.isLocalServer || preset.group == PresetGroup.custom || _allowLocal || needsOptIn)
                LocalNetworkToggle(
                  value: _allowLocal,
                  onChanged: (v) => setState(() {
                    _allowLocal = v;
                    _test = null;
                  }),
                ),
              SizedBox(height: t.space.lg),
              if (showKeyField)
                ApiKeyField(
                  controller: _key,
                  label: _keyLabel,
                  optional: preset.key == KeyRequirement.optional,
                  hint: preset.keyHint,
                  errorText: _submitted && _keyMissing ? 'Paste your ${_keyLabel.toLowerCase()} to continue.' : null,
                  onChanged: (_) => setState(() {}),
                )
              else
                SavedKeyTile(
                  label: _keyLabel,
                  onReplace: () => setState(() => _replacingKey = true),
                  onRemove: () => setState(() {
                    _clearKey = true;
                    _test = null;
                  }),
                ),
              if (_clearKey && _key.text.isEmpty) ...[
                SizedBox(height: t.space.xs),
                Text(
                  'The saved ${_keyLabel.toLowerCase()} will be deleted when you save.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: t.space.lg),
        ConnectionTestSection(
          onTest: () => unawaited(_testConnection()),
          testing: _testing,
          result: _test,
          preset: preset,
          savesFirst: _isEdit && _dirty,
        ),
        const SectionHeader('Default model'),
        DefaultModelSection(
          models: models,
          selectedId: _defaultModelId,
          onSelected: (m) => setState(() => _defaultModelId = m),
          useForNewChats: _useForNewChats,
          onUseForNewChats: (v) => setState(() => _useForNewChats = v),
        ),
        Theme(
          // ExpansionTile draws dividers when open; keep the page calm.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: const Text('Advanced'),
            subtitle: const Text('API type and extra headers'),
            initiallyExpanded: _headers.isNotEmpty || preset.group == PresetGroup.custom,
            childrenPadding: EdgeInsets.symmetric(horizontal: t.space.lg),
            children: [
              FlavorPicker(value: _flavor, onChanged: (f) => setState(() => _flavor = f)),
              SizedBox(height: t.space.lg),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('Extra headers', style: Theme.of(context).textTheme.titleSmall),
              ),
              SizedBox(height: t.space.xs),
              Text(
                'Sent with every request. Never put keys here; use the ${_keyLabel.toLowerCase()} field.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: t.space.md),
              HeadersEditor(
                initial: _original?.headers ?? const {},
                keyFieldLabel: _keyLabel.toLowerCase(),
                showAllErrors: _submitted,
                onChanged: (rows) => setState(() => _headers = rows),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

extension on Haptics {
  void outcome({required bool ok}) => ok ? success() : error();
}

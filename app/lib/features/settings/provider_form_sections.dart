import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../design/tokens.dart';
import '../../state/provider_location.dart';
import '../providers/connection.dart';
import '../providers/model_list.dart';
import '../providers/presets.dart';
import '../providers/status_chip.dart';
import 'settings_page.dart';

/// "Test connection" button plus the explained result.
class ConnectionTestSection extends StatelessWidget {
  const ConnectionTestSection({
    super.key,
    required this.onTest,
    required this.testing,
    required this.result,
    required this.preset,
    required this.savesFirst,
  });

  final VoidCallback onTest;
  final bool testing;
  final ConnectionResult? result;
  final ProviderPreset preset;

  /// Testing will also save pending edits (edit mode with changes).
  final bool savesFirst;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final r = result;
    final explained = r == null ? null : explainStatus(r.status, host: hostLabel(r.config.baseUrl), preset: preset);
    return SettingsPadding(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: testing ? null : onTest,
            icon: testing
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(testing ? 'Testing…' : (savesFirst ? 'Save & test connection' : 'Test connection')),
          ),
          if (explained != null && !testing) ...[
            SizedBox(height: t.space.md),
            Semantics(
              liveRegion: true,
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EndpointStatusChip(status: r!.status),
                  SizedBox(height: t.space.xs),
                  Text(explained.message, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Default model for this provider, and whether new chats use it.
class DefaultModelSection extends StatelessWidget {
  const DefaultModelSection({
    super.key,
    required this.models,
    required this.selectedId,
    required this.onSelected,
    required this.useForNewChats,
    required this.onUseForNewChats,
  });

  /// Null until the provider has answered a model listing.
  final List<ModelDescriptor>? models;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool useForNewChats;
  final ValueChanged<bool> onUseForNewChats;

  @override
  Widget build(BuildContext context) {
    final list = models;
    if (list == null) {
      return const ListTile(
        leading: Icon(Icons.info_outline_rounded),
        title: Text('Test the connection to choose a model'),
      );
    }
    if (list.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.info_outline_rounded),
        title: Text("This server didn't list any models"),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPadding(
          child: ModelChoiceList(models: list, selectedId: selectedId, onSelected: onSelected, shrinkWrap: true),
        ),
        SwitchListTile(
          title: const Text('Use for new chats'),
          subtitle: const Text('New chats start with this model'),
          value: useForNewChats && selectedId != null,
          onChanged: selectedId == null ? null : onUseForNewChats,
        ),
      ],
    );
  }
}

/// API type picker for the advanced section.
class FlavorPicker extends StatelessWidget {
  const FlavorPicker({super.key, required this.value, required this.onChanged});

  final ApiFlavor value;
  final ValueChanged<ApiFlavor> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => DropdownMenu<ApiFlavor>(
          width: c.maxWidth,
          initialSelection: value,
          label: const Text('API type'),
          onSelected: (v) {
            if (v != null) onChanged(v);
          },
          dropdownMenuEntries: [
            for (final f in ApiFlavor.values) DropdownMenuEntry(value: f, label: flavorLabel(f)),
          ],
        ),
      );
}

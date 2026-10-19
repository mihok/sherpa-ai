import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../services/mcp/input/host_settings.dart';
import '../../state/app_providers.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'state/input_providers.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// The server detail screen's "MCP Apps" section: whether the server offers
/// interactive views, a switch to turn them off for it, and the network
/// access granted to its views (per resource), each revocable.
class McpAppsSection extends ConsumerWidget {
  const McpAppsSection({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Consents and tools are read from the runtime: rebuild on every change.
    ref.watch(mcpRevisionProvider);
    final rt = ref.watch(mcpRuntimeProvider);
    final settings = ref.watch(mcpHostSettingsProvider(serverId));
    final theme = Theme.of(context);
    final t = SherpaTokens.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final uiTools = [for (final e in rt.toolsOf(serverId)) if (e.tool.uiResourceUri != null) e];
    final advertised = rt.manager.connectedOrNull(serverId)?.capabilities.supportsUi ?? false;
    final consents = rt.hostSettings.consentsOf(serverId);
    final offers = uiTools.isNotEmpty
        ? '${uiTools.length} of its tools show${uiTools.length == 1 ? 's' : ''} interactive content.'
        : advertised
            ? 'It supports interactive content, but none of its tools use it right now.'
            : 'It offers no interactive content.';
    return HeadingGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('MCP Apps'),
          SettingsPadding(child: Text(offers, style: muted)),
          SwitchListTile(
            key: const ValueKey('mcp-apps-switch'),
            secondary: const Icon(Icons.widgets_outlined),
            title: const Text('Show interactive content'),
            subtitle: const Text("Off: Sherpa doesn't tell the server it can show its views, and results appear as "
                'text. Views always run sandboxed, without your data or storage.'),
            isThreeLine: true,
            value: settings.appsEnabled,
            onChanged: (on) {
              ref.read(hapticsProvider).selection();
              unawaited(rt.updateHostSettings(serverId, settings.copyWith(appsEnabled: on)));
            },
          ),
          SettingsPadding(
            child: Padding(
              padding: EdgeInsets.only(top: t.space.sm, bottom: t.space.xs),
              child: Heading(level: 3, child: Text('Network access for its views', style: theme.textTheme.titleSmall)),
            ),
          ),
          if (consents.isEmpty)
            SettingsPadding(child: Text('None granted. Views ask before they use the network.', style: muted))
          else
            for (final c in consents)
              ListTile(
                key: ValueKey('mcp-consent-${c.resourceSha256}'),
                leading: Icon(c.origins.isEmpty ? Icons.cloud_off_outlined : Icons.public_rounded),
                title: Text(c.resourceUri.isEmpty ? 'A view' : c.resourceUri, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(c.origins.isEmpty ? 'Kept offline' : (c.origins.toList()..sort()).join('\n')),
                trailing: TextButton(
                  onPressed: () {
                    ref.read(hapticsProvider).selection();
                    unawaited(rt.hostSettings.revokeConsent(serverId, c.resourceSha256));
                  },
                  child: Text(c.origins.isEmpty ? 'Forget' : 'Revoke'),
                ),
              ),
        ],
      ),
    );
  }
}

/// The server detail screen's "Use of your model" section: sampling off /
/// ask / allowed in chats (off by default), the per-request token limit,
/// requests per minute, which model, and this run's "Allow for this chat"
/// answers.
class McpSamplingSection extends ConsumerWidget {
  const McpSamplingSection({super.key, required this.serverId});

  final String serverId;

  static String label(McpSamplingMode m) => switch (m) {
        McpSamplingMode.off => 'Off',
        McpSamplingMode.ask => 'Ask every time',
        McpSamplingMode.allowInChats => 'Allowed in chats',
      };

  static String detail(McpSamplingMode m) => switch (m) {
        McpSamplingMode.off => "The server can't use your model. Sherpa doesn't offer it.",
        McpSamplingMode.ask => 'You approve each request (or allow one chat) and review every answer.',
        McpSamplingMode.allowInChats => 'Requests during a chat run without asking; you still review every answer.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(mcpRevisionProvider);
    final rt = ref.watch(mcpRuntimeProvider);
    final s = ref.watch(mcpHostSettingsProvider(serverId));
    final theme = Theme.of(context);
    final t = SherpaTokens.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final grants = rt.hostSettings.chatGrants(serverId);
    final defaultModel = ref.watch(defaultModelProvider).value;
    void save(McpServerHostSettings next) {
      ref.read(hapticsProvider).selection();
      unawaited(rt.updateHostSettings(serverId, next));
    }

    return HeadingGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Use of your model'),
          SettingsPadding(
            child: Text(
              'A tool server can ask to run a prompt on your model ("sampling"). It sees only the answer you approve, '
              'never your chats.',
              style: muted,
            ),
          ),
          RadioGroup<McpSamplingMode>(
            groupValue: s.sampling,
            onChanged: (m) {
              if (m != null) save(s.copyWith(sampling: m));
            },
            child: Column(
              children: [
                for (final m in McpSamplingMode.values)
                  RadioListTile<McpSamplingMode>(
                    key: ValueKey('mcp-sampling-${m.name}'),
                    value: m,
                    title: Text(label(m)),
                    subtitle: Text(detail(m)),
                  ),
              ],
            ),
          ),
          if (s.samplingDeclared) ...[
            SettingsPadding(
              child: Padding(
                padding: EdgeInsets.only(top: t.space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Heading(level: 3, child: Text('Longest answer', style: theme.textTheme.titleSmall)),
                    SizedBox(height: t.space.xs),
                    Wrap(
                      spacing: t.space.xs,
                      children: [
                        for (final n in McpServerHostSettings.maxTokenChoices)
                          ChoiceChip(
                            label: Text('$n tokens'),
                            selected: s.samplingMaxTokens == n,
                            onSelected: (_) => save(s.copyWith(samplingMaxTokens: n)),
                          ),
                      ],
                    ),
                    SizedBox(height: t.space.md),
                    Heading(level: 3, child: Text('Requests per minute', style: theme.textTheme.titleSmall)),
                    SizedBox(height: t.space.xs),
                    Wrap(
                      spacing: t.space.xs,
                      children: [
                        for (final n in McpServerHostSettings.perMinuteChoices)
                          ChoiceChip(
                            label: Text('$n'),
                            selected: s.samplingPerMinute == n,
                            onSelected: (_) => save(s.copyWith(samplingPerMinute: n)),
                          ),
                      ],
                    ),
                    SizedBox(height: t.space.md),
                    Heading(level: 3, child: Text('Model', style: theme.textTheme.titleSmall)),
                    SizedBox(height: t.space.xs),
                    Text(
                      s.samplingModel == null
                          ? "The chat's current model (outside a chat: your default model)."
                          : 'Always ${ref.watch(modelDisplayNameProvider(s.samplingModel!))}.',
                      style: muted,
                    ),
                    Wrap(
                      spacing: t.space.sm,
                      children: [
                        if (s.samplingModel != null)
                          TextButton(
                            onPressed: () => save(s.copyWith(clearSamplingModel: true)),
                            child: const Text("Use the chat's model"),
                          ),
                        if (defaultModel != null && s.samplingModel != defaultModel)
                          TextButton(
                            onPressed: () => save(s.copyWith(samplingModel: defaultModel)),
                            child: Text('Always use ${ref.watch(modelDisplayNameProvider(defaultModel))}'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (grants.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.chat_outlined),
                title: Text('Allowed without asking in ${grants.length} chat${grants.length == 1 ? '' : 's'}'),
                subtitle: const Text('Until Sherpa restarts.'),
                trailing: TextButton(
                  onPressed: () {
                    ref.read(hapticsProvider).selection();
                    rt.hostSettings.revokeChatGrants(serverId);
                  },
                  child: const Text('Revoke'),
                ),
              ),
            SettingsPadding(
              child: Padding(
                padding: EdgeInsets.only(top: t.space.sm),
                child: const NoteBox(
                  icon: Icons.info_outline_rounded,
                  text: 'On-device models answer at low priority, after your own chats. Remote models may cost money. '
                      'The model never gets tools for these requests.',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

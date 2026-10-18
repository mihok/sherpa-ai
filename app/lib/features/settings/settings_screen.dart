import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import '../../design/widgets/section_header.dart';
import '../../routing/routes.dart';
import '../../state/app_providers.dart';
import '../../state/ui_preferences.dart';
import 'default_model_sheet.dart';
import 'settings_page.dart';

/// Settings root.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(providerConfigsProvider).value ?? const [];
    final choice = ref.watch(defaultModelProvider).value;
    final privacy = choice == null ? null : ref.watch(providerPrivacyProvider(choice.providerId));
    final ui = ref.watch(uiSettingsProvider);
    final notifier = ref.read(uiSettingsProvider.notifier);
    final reduced = SherpaTokens.of(context).motion.reduced;
    final t = SherpaTokens.of(context);

    return SettingsPage(
      title: 'Settings',
      children: [
        const SectionHeader('Models'),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Model providers'),
          subtitle: Text(switch (configs.length) {
            0 => 'None connected yet',
            1 => '1 connected',
            final n => '$n connected',
          }),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(Routes.providers),
        ),
        ListTile(
          leading: const Icon(Icons.star_outline_rounded),
          title: const Text('Default model'),
          subtitle: choice == null
              ? const Text('Not set: new chats will ask')
              : Padding(
                  padding: EdgeInsets.only(top: t.space.xxs),
                  child: Wrap(
                    spacing: t.space.sm,
                    runSpacing: t.space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(choice.modelId),
                      if (privacy != null) PrivacyBadge(location: privacy.location, host: privacy.host),
                    ],
                  ),
                ),
          enabled: configs.isNotEmpty,
          onTap: () => unawaited(showDefaultModelSheet(context)),
        ),
        const SectionHeader('Privacy'),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Privacy & data'),
          subtitle: const Text('Where your messages go, and why'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(Routes.privacy),
        ),
        const SectionHeader('Look & feel'),
        SettingsPadding(
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {ui.themeMode},
            onSelectionChanged: (s) {
              ref.read(hapticsProvider).selection();
              unawaited(notifier.update((u) => u.copyWith(themeMode: s.first)));
            },
          ),
        ),
        SizedBox(height: t.space.sm),
        if (defaultTargetPlatform == TargetPlatform.android)
          SwitchListTile(
            secondary: const Icon(Icons.palette_outlined),
            title: const Text('Wallpaper colors'),
            subtitle: const Text('Match your wallpaper on Android 12 and later'),
            value: ui.dynamicColor,
            onChanged: (v) => unawaited(notifier.update((u) => u.copyWith(dynamicColor: v))),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.vibration),
          title: const Text('Haptics'),
          subtitle: const Text('A light tap when you send, choose, or need to approve something'),
          value: ui.hapticsEnabled,
          onChanged: (v) => unawaited(notifier.update((u) => u.copyWith(hapticsEnabled: v))),
        ),
        ListTile(
          leading: const Icon(Icons.motion_photos_off_outlined),
          title: const Text('Motion'),
          subtitle: Text(
            reduced
                ? 'Reduced, following your system setting'
                : 'Follows your system "Reduce motion" / "Remove animations" setting',
          ),
        ),
        const SectionHeader('About'),
        ListTile(
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('About Sherpa'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go(Routes.about),
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Run setup again'),
          subtitle: const Text('Connect another model with the guided setup'),
          onTap: () => context.go(Routes.onboarding),
        ),
      ],
    );
  }
}

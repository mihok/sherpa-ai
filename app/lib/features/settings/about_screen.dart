import 'package:material_ui/material_ui.dart';

import '../../app_info.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/sherpa_mark.dart';
import '../diagnostics/diagnostics_screen.dart';
import 'settings_page.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final metric = theme.textTheme.metric.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SettingsPage(
      title: 'About',
      children: [
        SizedBox(height: t.space.xl),
        const Center(child: SherpaMark(size: 64)),
        SizedBox(height: t.space.md),
        Center(child: Text(AppInfo.name, style: theme.textTheme.headlineSmall)),
        Center(child: Text('Version ${AppInfo.version}', style: metric)),
        SizedBox(height: t.space.md),
        SettingsPadding(
          child: Text(
            'An open, local-first agent harness. It runs the agent loop on your phone and '
            'talks only to the models you connect.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SectionHeader('Build'),
        ListTile(title: const Text('App version'), trailing: Text(AppInfo.version, style: metric)),
        ListTile(title: const Text('Flutter'), trailing: Text(AppInfo.flutterVersion, style: metric)),
        ListTile(title: const Text('Dart'), trailing: Text(AppInfo.dartVersion, style: metric)),
        const SectionHeader('Support'),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text(DiagnosticsScreen.title),
          subtitle: const Text('A redacted report for bug reports: versions, device and settings, never your chats'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push<void>(
            MotionPageRoute(builder: (_) => const DiagnosticsScreen(), settings: const RouteSettings(name: 'diagnostics')),
          ),
        ),
        const SectionHeader('Legal'),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Open-source licenses'),
          subtitle: const Text('Sherpa is MIT licensed; see the notices for every component it includes'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: AppInfo.name,
            applicationVersion: AppInfo.version,
            applicationIcon: const Padding(padding: EdgeInsets.all(8), child: SherpaMark(size: 48)),
            applicationLegalese: 'MIT License',
          ),
        ),
      ],
    );
  }
}

import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart' show ExecutionLocation;

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';

/// The choose step's first option: "Run a model on this phone".
class OnDeviceChoiceCard extends StatelessWidget {
  const OnDeviceChoiceCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(t.space.lg),
          child: Row(
            children: [
              Icon(Icons.smartphone_rounded, color: t.semantic.onDevice),
              SizedBox(width: t.space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Run a model on this phone', style: theme.textTheme.titleMedium),
                    SizedBox(height: t.space.xxs),
                    Text(
                      'A small open model that fits this phone, downloaded once. Works offline; no account or key.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: t.space.sm),
                    const PrivacyBadge(location: ExecutionLocation.onDevice),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

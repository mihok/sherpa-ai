import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../design/tokens.dart';
import '../state/connectivity.dart';

/// Shows a slim "You're offline" bar above every screen while the device has
/// no network, and hands the status-bar inset to it.
///
/// It sits in `MaterialApp.builder`, above the Navigator, so it never
/// participates in page transitions and every route gets it for free. The
/// child is always wrapped the same way (only `removeTop` changes) so the
/// Router below keeps its state when connectivity flips.
class OfflineBannerHost extends ConsumerWidget {
  const OfflineBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(networkStatusProvider).value == NetworkStatus.offline;
    final motion = SherpaTokens.of(context).motion;
    return Column(
      children: [
        AnimatedSize(
          duration: motion.medium,
          curve: motion.standard,
          alignment: Alignment.topCenter,
          child: offline ? const OfflineBanner() : const SizedBox(width: double.infinity),
        ),
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: offline, child: child),
        ),
      ],
    );
  }
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onTertiaryContainer);
    return Material(
      color: scheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Semantics(
          liveRegion: true,
          container: true,
          label: "You're offline. Remote models can't be reached until you reconnect.",
          excludeSemantics: true,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.sm),
            child: Row(
              children: [
                Icon(Icons.wifi_off_rounded, size: 18, color: scheme.onTertiaryContainer),
                SizedBox(width: t.space.sm),
                Expanded(child: Text("You're offline · remote models are unavailable", style: style)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

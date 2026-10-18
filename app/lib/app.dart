import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'design/motion.dart';
import 'design/theme.dart';
import 'routing/router.dart';
import 'shell/offline_banner.dart';
import 'state/ui_preferences.dart';

/// The Sherpa app: theme (brand or wallpaper color, light/dark), router,
/// localizations and the global chrome every route shares.
///
/// Expects a `ProviderScope` above it with the overrides from `bootstrap()`.
class SherpaApp extends ConsumerStatefulWidget {
  const SherpaApp({super.key});

  @override
  ConsumerState<SherpaApp> createState() => _SherpaAppState();
}

class _SherpaAppState extends ConsumerState<SherpaApp> {
  // Theme construction derives and contrast-checks semantic colors; cache
  // per input scheme so rebuilds (e.g. a settings toggle) stay cheap.
  final Map<Object, ThemeData> _themes = {};

  ThemeData _theme(Brightness b, ColorScheme? dynamicScheme) =>
      _themes.putIfAbsent((b, dynamicScheme), () {
        if (_themes.length > 8) _themes.clear();
        return b == Brightness.light
            ? SherpaTheme.light(dynamicScheme: dynamicScheme)
            : SherpaTheme.dark(dynamicScheme: dynamicScheme);
      });

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final ui = ref.watch(uiSettingsProvider);
    return DynamicColorBuilder(
      // Null on iOS, Android < 12 and in tests → brand colors.
      builder: (lightDynamic, darkDynamic) => MaterialApp.router(
        title: 'Sherpa',
        debugShowCheckedModeBanner: false,
        restorationScopeId: 'sherpa',
        routerConfig: router,
        theme: _theme(Brightness.light, ui.dynamicColor ? lightDynamic : null),
        darkTheme: _theme(Brightness.dark, ui.dynamicColor ? darkDynamic : null),
        themeMode: ui.themeMode,
        // Material + Cupertino + Widgets strings (material_ui README).
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // App copy is English-only until the l10n pass.
        supportedLocales: const [Locale('en')],
        builder: (context, child) => MotionScope(
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(
            // Legacy `package:flutter/material.dart` widgets from third-party
            // packages resolve Theme/MaterialLocalizations through this.
            child: OfflineBannerHost(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

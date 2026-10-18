import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/contrast.dart';
import 'package:sherpa/design/semantic_palette.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/tokens.dart';

/// The privacy indicator is Sherpa's core trust signal, so its colors must be
/// legible (WCAG AA, 4.5:1) wherever they can appear: on every surface role,
/// and on their own tinted pill over each surface. Dynamic color means the
/// surfaces come from the user's wallpaper, so we check a spread of seeds.
void main() {
  const seeds = <String, Color>{
    'brand': Color(0xFF2B6F77),
    'red wallpaper': Color(0xFFD32F2F),
    'yellow wallpaper': Color(0xFFFFEB3B),
    'green wallpaper': Color(0xFF2E7D32),
    'purple wallpaper': Color(0xFF6750A4),
    'grey wallpaper': Color(0xFF808080),
    'orange wallpaper': Color(0xFFFF9800),
  };

  group('contrastRatio', () {
    test('black on white is 21:1 and is symmetric', () {
      expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
      expect(contrastRatio(const Color(0xFFFFFFFF), const Color(0xFF000000)), closeTo(21, 0.01));
    });

    test('identical colors are 1:1', () {
      expect(contrastRatio(const Color(0xFF777777), const Color(0xFF777777)), closeTo(1, 0.001));
    });

    test('ensureContrast darkens a light foreground on a light surface', () {
      const bg = Color(0xFFFAFAFA);
      final fixed = ensureContrast(const Color(0xFFFFD54F), (_) => [bg]);
      expect(contrastRatio(fixed, bg), greaterThanOrEqualTo(4.5));
    });

    test('ensureContrast lightens a dark foreground on a dark surface', () {
      const bg = Color(0xFF121212);
      final fixed = ensureContrast(const Color(0xFF1B5E20), (_) => [bg]);
      expect(contrastRatio(fixed, bg), greaterThanOrEqualTo(4.5));
    });
  });

  for (final brightness in Brightness.values) {
    for (final seed in seeds.entries) {
      test('semantic colors reach 4.5:1 on all surfaces (${seed.key}, ${brightness.name})', () {
        final scheme = ColorScheme.fromSeed(seedColor: seed.value, brightness: brightness);
        final s = semanticColorsFor(scheme);
        final surfaces = surfaceRoles(scheme);
        final named = {
          'onDevice': s.onDevice,
          'leavesDevice': s.leavesDevice,
          'success': s.success,
          'warning': s.warning,
          'danger': s.danger,
          'reasoning': s.reasoning,
        };
        for (final fg in named.entries) {
          for (final bg in surfaces) {
            expect(contrastRatio(fg.value, bg), greaterThanOrEqualTo(kMinTextContrast),
                reason: '${fg.key} on $bg');
          }
        }
        // The pills: text in the semantic color on its own 12% tint.
        for (final fg in [s.onDevice, s.leavesDevice, s.success, s.warning, s.danger]) {
          for (final bg in surfaces) {
            final pill = Color.alphaBlend(fg.withValues(alpha: kSemanticTintAlpha), bg);
            expect(contrastRatio(fg, pill), greaterThanOrEqualTo(kMinTextContrast), reason: 'pill $fg on $bg');
          }
        }
      });
    }
  }

  test('on-device and leaves-device stay distinguishable by hue', () {
    for (final b in Brightness.values) {
      final s = SherpaTheme.build(SherpaTheme.brandScheme(b)).extension<SherpaTokens>()!.semantic;
      final h1 = HSLColor.fromColor(s.onDevice).hue;
      final h2 = HSLColor.fromColor(s.leavesDevice).hue;
      final delta = (h1 - h2).abs() % 360;
      expect(delta > 180 ? 360 - delta : delta, greaterThan(45));
    }
  });

  test('the theme carries complete tokens', () {
    final theme = SherpaTheme.light();
    final tokens = theme.extension<SherpaTokens>()!;
    expect(tokens.space.minTouchTarget, 48);
    expect(tokens.motion.reduced, isFalse);
    expect(theme.useMaterial3, isTrue);
    expect(SherpaTheme.dark().colorScheme.brightness, Brightness.dark);
  });

  test('dynamic schemes are re-seeded from the wallpaper primary', () {
    final wallpaper = ColorScheme.fromSeed(seedColor: const Color(0xFFD32F2F));
    final theme = SherpaTheme.light(dynamicScheme: wallpaper);
    expect(theme.colorScheme.primary, ColorScheme.fromSeed(seedColor: wallpaper.primary).primary);
  });
}

import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Component themes. The intent is "calm": flat surfaces separated by tone
/// rather than shadows, generous 48dp targets, one corner language
/// (12/16/24), and floating snackbars that never cover the composer.
///
/// Everything here reads from [ColorScheme] + [SherpaTokens]; no literals.
final class SherpaComponentThemes {
  SherpaComponentThemes(this.scheme, this.tokens);

  final ColorScheme scheme;
  final SherpaTokens tokens;

  RoundedRectangleBorder _rounded(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  AppBarThemeData get appBar => AppBarThemeData(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        // Tone shift instead of a shadow when content scrolls under.
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
      );

  CardThemeData get card => CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radius.lg),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      );

  ChipThemeData get chip => ChipThemeData(
        shape: _rounded(tokens.radius.sm),
        side: BorderSide(color: scheme.outlineVariant),
        padding: EdgeInsets.symmetric(horizontal: tokens.space.xs),
        labelPadding: EdgeInsets.symmetric(horizontal: tokens.space.sm),
      );

  InputDecorationThemeData get input {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radius.md),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: EdgeInsets.symmetric(horizontal: tokens.space.lg, vertical: tokens.space.md + 2),
      border: border(scheme.outlineVariant),
      enabledBorder: border(scheme.outlineVariant),
      focusedBorder: border(scheme.primary, 2),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 2),
      disabledBorder: border(scheme.outlineVariant.withValues(alpha: 0.5)),
      // Long validation messages (URL policy, header rules) must wrap.
      errorMaxLines: 4,
      helperMaxLines: 4,
    );
  }

  BottomSheetThemeData get bottomSheet => BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(tokens.radius.xl)),
        ),
        clipBehavior: Clip.antiAlias,
        // Sheets on tablets read better as a centred column.
        constraints: const BoxConstraints(maxWidth: 640),
      );

  DialogThemeData get dialog => DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: _rounded(tokens.radius.xl),
      );

  NavigationBarThemeData get navigationBar => NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        elevation: 0,
      );

  NavigationRailThemeData get navigationRail => NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        labelType: NavigationRailLabelType.all,
        groupAlignment: -1,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      );

  SnackBarThemeData get snackBar => SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: _rounded(tokens.radius.md),
        backgroundColor: scheme.inverseSurface,
        actionTextColor: scheme.inversePrimary,
        insetPadding: EdgeInsets.fromLTRB(tokens.space.lg, 0, tokens.space.lg, tokens.space.lg),
        showCloseIcon: false,
      );

  ListTileThemeData get listTile => ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: tokens.space.lg),
        minVerticalPadding: tokens.space.sm,
        shape: _rounded(tokens.radius.md),
        iconColor: scheme.onSurfaceVariant,
        selectedColor: scheme.onSecondaryContainer,
        selectedTileColor: scheme.secondaryContainer,
      );

  FilledButtonThemeData get filledButton => FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(tokens.space.minTouchTarget, tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.xl),
        ),
      );

  OutlinedButtonThemeData get outlinedButton => OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(tokens.space.minTouchTarget, tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.xl),
        ),
      );

  TextButtonThemeData get textButton => TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(tokens.space.minTouchTarget, tokens.space.minTouchTarget),
          padding: EdgeInsets.symmetric(horizontal: tokens.space.md),
        ),
      );

  DividerThemeData get divider => DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1);

  TooltipThemeData get tooltip => TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(tokens.radius.sm),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface),
      );

  FloatingActionButtonThemeData get fab => FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 1,
        highlightElevation: 2,
        shape: _rounded(tokens.radius.lg),
      );
}

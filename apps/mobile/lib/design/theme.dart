/// Theme assembly from generated tokens.
///
/// Nothing here invents a colour. Every value traces to
/// `packages/tokens/tokens.json` via `tokens.dart`, so the Flutter app and the
/// Next.js dashboard cannot drift.
///
/// Dark is the default — see docs/design.md §2. The Moderate amber only clears
/// contrast on a dark surface (1.79 on light vs 9.49 on dark).
///
/// ### Material You, on the MEC-AI palette
///
/// The product palette is **blue, green, red and white**: blue is the data and
/// interaction hue, green and red are reserved clinical status, white is ink.
/// Amber survives as one deliberate exception — the Moderate risk band, which
/// needs a third status hue and only clears contrast on dark.
///
/// The MD3 [ColorScheme] is therefore **pinned to those tokens, not seeded**.
/// `ColorScheme.fromSeed` harmonises a seed into a full tonal palette, which
/// produced `primary #A7C8FF` (a pale blue that is not the token blue),
/// `tertiary #DBBDE2` (pink), and cool greys `#8D9199` / `#282A2F` that fight
/// the warm MEC-AI ramp. Screens that hardcode `c.card` and `c.series1` dodged
/// it; anything on a theme default did not. Pinning every role removes that leak.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Surface + ink for one mode, so widgets read roles instead of raw colours.
@immutable
class MecColors extends ThemeExtension<MecColors> {
  const MecColors({
    required this.page,
    required this.card,
    required this.elevated,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.gridline,
    required this.baseline,
    required this.hairline,
    required this.series1,
    required this.series2,
    required this.onAccent,
  });

  final Color page;
  final Color card;
  final Color elevated;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color gridline;
  final Color baseline;
  final Color hairline;
  final Color series1;
  final Color series2;

  /// Ink for a surface *filled* with [series1].
  ///
  /// Near-black on dark, not white: white on `#3987E5` measures 4.5:1 — it
  /// measures **3.64**, below AA for the 15px label a button carries. The page
  /// ink measures **5.41**. MD3 dark schemes put dark ink on a colour fill for
  /// exactly this reason, so this is both the accessible and the canonical choice.
  final Color onAccent;

  static const MecColors dark = MecColors(
    page: MecSurfaceDark.page,
    card: MecSurfaceDark.card,
    elevated: MecSurfaceDark.elevated,
    inkPrimary: MecSurfaceDark.inkPrimary,
    inkSecondary: MecSurfaceDark.inkSecondary,
    inkMuted: MecSurfaceDark.inkMuted,
    gridline: MecSurfaceDark.gridline,
    baseline: MecSurfaceDark.baseline,
    hairline: MecSurfaceDark.hairline,
    series1: MecSeries.s1Dark,
    series2: MecSeries.s2Dark,
    onAccent: MecSurfaceDark.page,
  );

  static const MecColors light = MecColors(
    page: MecSurfaceLight.page,
    card: MecSurfaceLight.card,
    elevated: MecSurfaceLight.elevated,
    inkPrimary: MecSurfaceLight.inkPrimary,
    inkSecondary: MecSurfaceLight.inkSecondary,
    inkMuted: MecSurfaceLight.inkMuted,
    gridline: MecSurfaceLight.gridline,
    baseline: MecSurfaceLight.baseline,
    hairline: MecSurfaceLight.hairline,
    series1: MecSeries.s1Light,
    series2: MecSeries.s2Light,
    // Light mode is not shipped (main.dart pins dark). White and near-black both
    // land at ~4.4 on the light blue, so this needs review before it ever is.
    onAccent: MecSurfaceDark.inkPrimary,
  );

  /// MD3 `primaryContainer` — the data hue as a tonal fill, for chips and pills.
  ///
  /// Derived, not declared: [series1] at [MecState.press] over [card]. It tracks
  /// the palette automatically and adds no value to the token file.
  Color get accentContainer =>
      Color.alphaBlend(series1.withValues(alpha: MecState.press), card);

  /// MD3 `errorContainer`, derived the same way from the High-risk red.
  Color get errorContainer =>
      Color.alphaBlend(MecRiskBand.high.color.withValues(alpha: MecState.press), card);

  /// A tonal fill for any status colour — the MD3 container recipe, one place.
  ///
  /// Ink on the result must be [inkPrimary] (15.1:1), not the status hue itself
  /// (4.15:1, under AA for small text). The hue is fine for an *icon* on it,
  /// which only needs 3:1.
  Color containerFor(Color status) =>
      Color.alphaBlend(status.withValues(alpha: MecState.press), card);

  @override
  MecColors copyWith({
    Color? page,
    Color? card,
    Color? elevated,
    Color? inkPrimary,
    Color? inkSecondary,
    Color? inkMuted,
    Color? gridline,
    Color? baseline,
    Color? hairline,
    Color? series1,
    Color? series2,
    Color? onAccent,
  }) {
    return MecColors(
      page: page ?? this.page,
      card: card ?? this.card,
      elevated: elevated ?? this.elevated,
      inkPrimary: inkPrimary ?? this.inkPrimary,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkMuted: inkMuted ?? this.inkMuted,
      gridline: gridline ?? this.gridline,
      baseline: baseline ?? this.baseline,
      hairline: hairline ?? this.hairline,
      series1: series1 ?? this.series1,
      series2: series2 ?? this.series2,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  MecColors lerp(MecColors? other, double t) {
    if (other == null) return this;
    return MecColors(
      page: Color.lerp(page, other.page, t)!,
      card: Color.lerp(card, other.card, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      inkPrimary: Color.lerp(inkPrimary, other.inkPrimary, t)!,
      inkSecondary: Color.lerp(inkSecondary, other.inkSecondary, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      gridline: Color.lerp(gridline, other.gridline, t)!,
      baseline: Color.lerp(baseline, other.baseline, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      series1: Color.lerp(series1, other.series1, t)!,
      series2: Color.lerp(series2, other.series2, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// The MD3 state layer, as a widget-state property.
///
/// Material You models interaction as an **opacity overlay in the foreground
/// colour**, never a different hue — so a pressed button is the same blue with
/// ink laid over it, not a second blue. Opacities come from [MecState].
WidgetStateProperty<Color?> mecStateLayer(Color ink) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return ink.withValues(alpha: MecState.press);
      }
      if (states.contains(WidgetState.hovered)) {
        return ink.withValues(alpha: MecState.hover);
      }
      if (states.contains(WidgetState.focused)) {
        return ink.withValues(alpha: MecState.focus);
      }
      return null;
    });

/// Convenience accessor: `context.mec.inkMuted`.
extension MecThemeContext on BuildContext {
  MecColors get mec => Theme.of(this).extension<MecColors>() ?? MecColors.dark;

  /// True when the platform asks for reduced motion.
  ///
  /// Every ambient or looping animation must check this. A pulsing red alert is
  /// a vestibular hazard for someone who may be having a cardiac event
  /// (docs/design.md §3.6).
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// [d], or zero when the platform asks for reduced motion.
  ///
  /// For transitions that should *arrive* rather than animate. Ambient loops
  /// need stopping outright, not shortening — check [reduceMotion] for those.
  Duration stilled(Duration d) => reduceMotion ? Duration.zero : d;
}

abstract final class MecTheme {
  static ThemeData dark() => _build(MecColors.dark, Brightness.dark);
  static ThemeData light() => _build(MecColors.light, Brightness.light);

  static ThemeData _build(MecColors c, Brightness brightness) {
    final scheme = _scheme(c, brightness);
    final text = _textTheme(c);

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: c.page,
      canvasColor: c.page,
      extensions: <ThemeExtension<dynamic>>[c],

      // MD3's own ink. Every tap gets a state layer plus this ripple.
      splashFactory: InkSparkle.splashFactory,
      // 48dp minimum touch target, per MD3 and WCAG 2.5.5.
      materialTapTargetSize: MaterialTapTargetSize.padded,

      appBarTheme: AppBarTheme(
        backgroundColor: c.page,
        foregroundColor: c.inkPrimary,
        // The tint is Material's elevation overlay. Off — elevation here is a
        // hairline plus a surface step (docs/design.md §3.5).
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: MecType.sectionTitle.copyWith(color: c.inkPrimary),
        iconTheme: IconThemeData(color: c.inkSecondary, size: 22),
      ),

      cardTheme: CardThemeData(
        color: c.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MecRadius.card),
          side: BorderSide(color: c.hairline),
        ),
        margin: EdgeInsets.zero,
      ),

      dividerTheme: DividerThemeData(color: c.gridline, thickness: 1, space: 1),

      // ── Controls. Every one is a pill (MecRadius.control), the single most
      // recognisable Material You trait, and every one carries a state layer.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.series1,
          foregroundColor: c.onAccent,
          disabledBackgroundColor: c.elevated,
          disabledForegroundColor: c.inkMuted,
          minimumSize: const Size.fromHeight(50),
          padding: const EdgeInsets.symmetric(
            horizontal: MecSpace.s24,
            vertical: MecSpace.s12,
          ),
          shape: const StadiumBorder(),
          textStyle: MecType.body.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ).copyWith(overlayColor: mecStateLayer(c.onAccent)),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.inkPrimary,
          minimumSize: const Size.fromHeight(50),
          padding: const EdgeInsets.symmetric(
            horizontal: MecSpace.s24,
            vertical: MecSpace.s12,
          ),
          shape: const StadiumBorder(),
          side: BorderSide(color: c.baseline),
          textStyle: MecType.body.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ).copyWith(overlayColor: mecStateLayer(c.series1)),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.series1,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(
            horizontal: MecSpace.s16,
            vertical: MecSpace.s8,
          ),
          shape: const StadiumBorder(),
          textStyle: MecType.label.copyWith(fontWeight: FontWeight.w600),
        ).copyWith(overlayColor: mecStateLayer(c.series1)),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.inkSecondary,
          shape: const StadiumBorder(),
        ).copyWith(overlayColor: mecStateLayer(c.series1)),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.series1,
        foregroundColor: c.onAccent,
        // MD3 gives FABs a soft square, not a circle.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MecRadius.md),
        ),
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: MecType.label.copyWith(fontWeight: FontWeight.w600),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: c.card,
        selectedColor: c.accentContainer,
        side: BorderSide(color: c.hairline),
        shape: const StadiumBorder(),
        labelStyle: MecType.label.copyWith(color: c.inkSecondary),
        padding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s12,
          vertical: MecSpace.s8,
        ),
      ),

      // MD3 filled text field: rounded top, square bottom, 2px focus underline.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.elevated,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s16,
          vertical: MecSpace.s16,
        ),
        labelStyle: MecType.label.copyWith(color: c.inkSecondary),
        hintStyle: MecType.body.copyWith(color: c.inkMuted),
        helperStyle: MecType.axisTick.copyWith(color: c.inkMuted),
        helperMaxLines: 3,
        border: _field(c.baseline, 1),
        enabledBorder: _field(c.baseline, 1),
        focusedBorder: _field(c.series1, 2),
        errorBorder: _field(MecRiskBand.high.color, 2),
        focusedErrorBorder: _field(MecRiskBand.high.color, 2),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.series1,
        selectionColor: c.series1.withValues(alpha: MecState.drag),
        selectionHandleColor: c.series1,
      ),

      // ── Floating surfaces. The only two places a shadow is correct.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBarrierColor: Colors.black.withValues(alpha: 0.6),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(MecRadius.xl)),
        ),
        dragHandleColor: c.baseline,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MecRadius.xl),
        ),
        titleTextStyle: MecType.sectionTitle.copyWith(color: c.inkPrimary),
        contentTextStyle: MecType.body.copyWith(color: c.inkSecondary),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.elevated,
        contentTextStyle: MecType.body.copyWith(color: c.inkPrimary),
        actionTextColor: c.series1,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MecRadius.sm),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.elevated,
          borderRadius: BorderRadius.circular(MecRadius.xs),
          border: Border.all(color: c.hairline),
        ),
        textStyle: MecType.axisTick.copyWith(color: c.inkPrimary),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.series1,
        linearTrackColor: c.gridline,
        circularTrackColor: Colors.transparent,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: c.inkSecondary,
        textColor: c.inkPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MecRadius.sm),
        ),
      ),

      // FadeForwards is MD3's own page transition; it needs no curve override.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// The MD3 filled-field underline: 12px top corners, square bottom.
  static UnderlineInputBorder _field(Color color, double width) =>
      UnderlineInputBorder(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(MecRadius.sm),
          topRight: Radius.circular(MecRadius.sm),
        ),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Every MD3 role, pinned to a token.
  ///
  /// Written out rather than seeded so no generated tone can enter the palette.
  /// MEC-AI has one interaction hue, so secondary and tertiary are also blue —
  /// green and red are reserved clinical status and must never become an accent.
  static ColorScheme _scheme(MecColors c, Brightness brightness) => ColorScheme(
        brightness: brightness,
        primary: c.series1,
        onPrimary: c.onAccent,
        primaryContainer: c.accentContainer,
        onPrimaryContainer: c.inkPrimary,
        secondary: c.series1,
        onSecondary: c.onAccent,
        secondaryContainer: c.accentContainer,
        onSecondaryContainer: c.inkPrimary,
        tertiary: c.series1,
        onTertiary: c.onAccent,
        tertiaryContainer: c.accentContainer,
        onTertiaryContainer: c.inkPrimary,
        error: MecRiskBand.high.color,
        // White on the alarm red measures 4.80 — the one status fill that takes
        // white ink rather than dark.
        onError: MecSurfaceDark.inkPrimary,
        errorContainer: c.errorContainer,
        onErrorContainer: c.inkPrimary,
        surface: c.card,
        onSurface: c.inkPrimary,
        onSurfaceVariant: c.inkSecondary,
        surfaceDim: c.page,
        surfaceBright: c.elevated,
        surfaceContainerLowest: c.page,
        surfaceContainerLow: c.card,
        surfaceContainer: c.card,
        surfaceContainerHigh: c.elevated,
        surfaceContainerHighest: c.elevated,
        outline: c.baseline,
        outlineVariant: c.gridline,
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: c.inkPrimary,
        onInverseSurface: c.page,
        inversePrimary: c.series1,
        surfaceTint: c.series1,
      );

  static TextTheme _textTheme(MecColors c) => TextTheme(
        displayLarge: MecType.heroFigure.copyWith(color: c.inkPrimary),
        headlineMedium: MecType.statValue.copyWith(color: c.inkPrimary),
        titleMedium: MecType.sectionTitle.copyWith(color: c.inkPrimary),
        bodyMedium: MecType.body.copyWith(color: c.inkSecondary),
        labelMedium: MecType.label.copyWith(color: c.inkSecondary),
        labelSmall: MecType.axisTick.copyWith(color: c.inkMuted),
      );
}

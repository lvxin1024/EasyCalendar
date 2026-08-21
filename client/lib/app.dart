import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'application/item_controller.dart';
import 'config/app_config.dart';
import 'features/shell/home_shell.dart';
import 'features/onboarding/first_run_page.dart';
import 'utils/date_formatters.dart';
import 'widget/widget_deep_link_controller.dart';

class EasyCalendarApp extends StatelessWidget {
  const EasyCalendarApp({
    super.key,
    required this.config,
    required this.controller,
    required this.widgetDeepLinks,
  });

  final AppConfig config;
  final ItemController controller;
  final WidgetDeepLinkController widgetDeepLinks;

  @override
  Widget build(BuildContext context) {
    // An Apple-like palette: iOS system blue drives structure and selection,
    // a single red (system red) reserves the living moment — today, the
    // now-line, and deadlines — and green marks ordinary scheduled events.
    // Neutrals follow iOS grouped-background greys so surfaces stay quiet and
    // let translucent "liquid glass" chrome read clearly.
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF007AFF),
          onPrimary: const Color(0xFFFFFFFF),
          primaryContainer: const Color(0xFFE5F1FF),
          onPrimaryContainer: const Color(0xFF004A99),
          secondary: const Color(0xFF34C759),
          onSecondary: const Color(0xFFFFFFFF),
          secondaryContainer: const Color(0xFFE3F9E9),
          onSecondaryContainer: const Color(0xFF0B3A1C),
          tertiary: const Color(0xFFFF3B30),
          onTertiary: const Color(0xFFFFFFFF),
          tertiaryContainer: const Color(0xFFFFE5E3),
          onTertiaryContainer: const Color(0xFF5B0A00),
          error: const Color(0xFFFF3B30),
          onError: const Color(0xFFFFFFFF),
          surface: const Color(0xFFFFFFFF),
          onSurface: const Color(0xFF1C1C1E),
          onSurfaceVariant: const Color(0xFF6E6E73),
          outline: const Color(0xFFC6C6C8),
          outlineVariant: const Color(0xFFE5E5EA),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFF8F8FA),
          surfaceContainer: const Color(0xFFF2F2F7),
          surfaceContainerHigh: const Color(0xFFECECF0),
          surfaceContainerHighest: const Color(0xFFE5E5EA),
          inverseSurface: const Color(0xFF1C1C1E),
          onInverseSurface: const Color(0xFFF2F2F7),
          inversePrimary: const Color(0xFFA8CFFF),
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final theme = base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF2F2F7),
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(letterSpacing: 0.2),
        labelSmall: base.textTheme.labelSmall?.copyWith(letterSpacing: 0.3),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          color: scheme.onSurface,
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      cardTheme: base.cardTheme.copyWith(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant),
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.surface
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
          side: const WidgetStatePropertyAll(
            BorderSide(color: Colors.transparent),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        backgroundColor: scheme.surface,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: const CircleBorder(),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      tooltipTheme: base.tooltipTheme.copyWith(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        iconColor: scheme.onSurfaceVariant,
      ),
    );
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: config.appName,
        debugShowCheckedModeBanner: false,
        locale: _locale(controller.preferences.localeName, config.locale),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => DateFormattingScope(
          clockFormat: controller.preferences.clockFormat,
          child: child ?? const SizedBox.shrink(),
        ),
        theme: theme,
        home:
            controller.preferences.onboardingCompleted ||
                (!controller.initialized && controller.error != null)
            ? HomeShell(
                config: config,
                controller: controller,
                widgetDeepLinks: widgetDeepLinks,
              )
            : FirstRunPage(config: config, controller: controller),
      ),
    );
  }

  static Locale _locale(String value, Locale fallback) {
    if (value == 'system') return fallback;
    final parts = value.replaceAll('_', '-').split('-');
    if (parts.first.isEmpty) return fallback;
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }
}

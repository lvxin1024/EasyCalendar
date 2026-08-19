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
    final baseScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2563EB),
      brightness: Brightness.light,
    );
    final scheme = baseScheme.copyWith(
      secondary: const Color(0xFF0F766E),
      tertiary: const Color(0xFFEA6A47),
      error: const Color(0xFFB42318),
      surface: const Color(0xFFFCFCFD),
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
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: scheme,
          scaffoldBackgroundColor: const Color(0xFFF7F8FA),
          dividerTheme: const DividerThemeData(
            color: Color(0xFFE4E7EC),
            thickness: 1,
            space: 1,
          ),
          cardTheme: const CardThemeData(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: Color(0xFFE4E7EC)),
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFD0D5DD)),
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
            filled: true,
            fillColor: Colors.white,
          ),
          navigationRailTheme: const NavigationRailThemeData(
            backgroundColor: Colors.white,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
          ),
        ),
        home: controller.preferences.onboardingCompleted ||
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

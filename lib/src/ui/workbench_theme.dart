import 'package:flutter/material.dart';

const Color connectedStatusColor = Color(0xff4caf50);
const Color inactiveStatusColor = Color(0xff757575);
const Color conversationUserMarkerColor = Color(0xff616161);
const Color keywordHighlightBackgroundColor = Color(0xffd6d6d6);
const Color keywordHighlightForegroundColor = Color(0xff121212);

final ColorScheme workBenchColorScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xff808080),
  brightness: Brightness.dark,
  dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  error: const Color(0xffbdbdbd),
  onError: const Color(0xff121212),
  errorContainer: const Color(0xff424242),
  onErrorContainer: const Color(0xfff5f5f5),
);

ThemeData buildWorkBenchTheme() {
  return ThemeData(
    colorScheme: workBenchColorScheme,
    useMaterial3: true,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(fontSize: 14, height: 1.4),
      bodySmall: TextStyle(fontSize: 12, height: 1.35),
      labelLarge: TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: const CardThemeData(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

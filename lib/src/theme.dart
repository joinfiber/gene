import 'package:flutter/material.dart';

/// The app's single source of visual truth: a dark, full-bleed aesthetic built
/// around a teal accent. Centralized so every surface stays consistent.
ThemeData buildGeneTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.tealAccent,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: Colors.black,
  );
}

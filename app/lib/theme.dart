import 'package:flutter/material.dart';

/// Identidad visual (colores tomados del ícono).
const brandSeed = Color(0xFF5B4FE0);
const brandMint = Color(0xFF2EE6B8);

const statusColors = {
  'ok': Colors.green,
  'at_risk': Colors.orange,
  'late': Colors.red,
  'done': Colors.grey,
};
const statusLabels = {'ok': 'A tiempo', 'at_risk': 'En riesgo', 'late': 'Atrasada', 'done': 'Hecha'};

Color contextColor(String? ctx) {
  switch (ctx) {
    case 'trabajo':
      return const Color(0xFF00897B);
    case 'universidad':
      return const Color(0xFF5B4FE0);
    default:
      return const Color(0xFFEF6C00);
  }
}

Color hexColor(String hex) {
  final h = hex.replaceAll('#', '');
  return Color(int.tryParse('FF$h', radix: 16) ?? 0xFFFFF59D);
}

bool isDarkHex(String hex) => ThemeData.estimateBrightnessForColor(hexColor(hex)) == Brightness.dark;

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: brandSeed, brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: const AppBarTheme(centerTitle: false),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// Logo redondeado pequeño para barras de título.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/icon/icon.png', width: size, height: size, fit: BoxFit.cover),
      );
}

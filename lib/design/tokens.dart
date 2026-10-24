import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// DocScan design tokens — "liquid glass over the scanner bed".
///
/// The camera view is the dark, real world (Ink). Everything that floats
/// above it — controls, sheets, dialogs — is frosted glass. Scanned output
/// lives on Paper. One accent (Clover) marks anything the scanner decided:
/// detected corners, progress, primary actions.
abstract final class Ds {
  // ---- palette ----
  static const ink = Color(0xFF14181C); // immersive camera backdrop
  static const paper = Color(0xFFFAFAF8); // scanned-document surface
  static const frost = Color(0xFFF2F4F3); // glass fill (use @72% + blur)
  static const clover = Color(0xFF2F8F63); // the one accent
  static const cloverDim = Color(0xFF22654A);
  static const text = Color(0xFF1A1F23);
  static const textDim = Color(0xFF71787E);
  static const stroke = Color(0x59FFFFFF); // glass edge highlight @34%
  static const danger = Color(0xFFB3402E);

  // ---- glass recipe ----
  static const glassBlur = 24.0;
  static const glassFill = Color(0xB8F2F4F3); // frost @72%
  static const glassFillDark = Color(0x9920262B); // over camera, darker frost

  // ---- shape ----
  static const radius = 22.0; // glass sheets
  static const radiusSmall = 14.0; // chips, buttons inside glass

  // ---- motion ----
  // The app's motion grammar: things respond to the hand quickly, settle
  // softly. Emphasized = page transitions and the scan sweep.
  static const durFast = Duration(milliseconds: 140);
  static const durMid = Duration(milliseconds: 260);
  static const durEmph = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;
  static const curveSpring = Curves.easeOutBack;

  // ---- type ----
  // System face only (SF Pro on devices); mono for metadata a scanner
  // would print: page counts, file names, dates.
  static const mono = 'monospace';

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: clover,
        brightness: Brightness.light,
      ).copyWith(primary: clover, secondary: clover, error: danger),
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
          letterSpacing: -0.2,
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// Frosted glass container — the app's signature surface. Use only for
/// things that float over content (camera controls, sheets, bars).
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.dark = false,
    this.radius = Ds.radius,
    this.padding,
  });

  final Widget child;
  final bool dark; // over the camera: darker frost keeps controls legible
  final double radius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: createGlassBlur(),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: dark ? Ds.glassFillDark : Ds.glassFill,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Ds.stroke, width: 0.8),
          ),
          child: child,
        ),
      ),
    );
    return body;
  }
}

ImageFilter createGlassBlur() => ImageFilter.blur(sigmaX: Ds.glassBlur, sigmaY: Ds.glassBlur);

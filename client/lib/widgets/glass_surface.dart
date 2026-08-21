import 'dart:ui';

import 'package:flutter/material.dart';

/// A frosted "liquid glass" surface in the spirit of Apple's translucent
/// material: it blurs whatever renders behind it, tints it with a translucent
/// color, and draws a hairline highlight on top.
///
/// Use it sparingly — on navigation chrome, floating controls, and sheets —
/// never behind dense content, where the blur only costs performance without
/// adding hierarchy.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.tint = const Color(0x99FFFFFF),
    this.borderColor = const Color(0x33FFFFFF),
    this.blur = 24,
    this.padding,
  });

  /// Child to render above the translucent layer.
  final Widget child;

  /// Outer corner radius of the glass panel.
  final BorderRadius borderRadius;

  /// Translucent fill color. Defaults to ~60% white for light chrome.
  final Color tint;

  /// Hairline highlight / edge color. Defaults to ~20% white.
  final Color borderColor;

  /// Blur sigma applied to the backdrop.
  final double blur;

  /// Optional inner padding around [child].
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor),
          ),
          child: content,
        ),
      ),
    );
  }
}

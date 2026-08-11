import 'package:flutter/material.dart';

const tagPalette = <Color>[
  Color(0xFF2563EB),
  Color(0xFF0F766E),
  Color(0xFFB42318),
  Color(0xFF7A5AF8),
  Color(0xFFCA8504),
  Color(0xFFB54708),
  Color(0xFF027A48),
  Color(0xFFC11574),
];

Color colorForTag(String tag, Map<String, int> configured) {
  final explicit = configured[tag];
  if (explicit != null) return Color(explicit);
  var hash = 0;
  for (final unit in tag.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return tagPalette[hash % tagPalette.length];
}

Color onTagColor(Color color) =>
    color.computeLuminance() > 0.52 ? Colors.black87 : Colors.white;

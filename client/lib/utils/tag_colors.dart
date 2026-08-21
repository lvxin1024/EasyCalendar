import 'package:flutter/material.dart';

// Ophelia's scattered blooms: five named flower colors kept vivid against the
// muted greens of the rest of the interface, plus river teal, rust, and moss to
// keep them grounded in the painting.
const tagPalette = <Color>[
  Color(0xFFBE3341), // 罂粟红 poppy red
  Color(0xFF3F7C78), // 河青 river teal
  Color(0xFF785393), // 三色堇紫 pansy purple
  Color(0xFF6495ED), // 矢车菊蓝 cornflower blue
  Color(0xFFE2AF3E), // 毛茛金 buttercup gold
  Color(0xFFA85738), // 桂竹香赭 rust
  Color(0xFF4F7658), // 苔绿 moss green
  Color(0xFFD87493), // 野玫瑰粉 wild rose pink
];

Color colorForTag(String tag, Map<String, int> configured) {
  final explicit = configured[tag];
  if (explicit != null) return Color(explicit);
  return tagPalette[_paletteIndex(tag)];
}

Color colorForItemAccent({
  required String collectionId,
  required List<String> tags,
  required Map<String, int> tagColors,
  required Map<String, int> collectionColors,
}) {
  if (tags.isNotEmpty) return colorForTag(tags.first, tagColors);
  final collectionColor = collectionColors[collectionId];
  if (collectionColor != null) return Color(collectionColor);
  return tagPalette[_paletteIndex('collection:$collectionId')];
}

int _paletteIndex(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash % tagPalette.length;
}

Color onTagColor(Color color) =>
    color.computeLuminance() > 0.22 ? const Color(0xFF1E2723) : Colors.white;

import 'package:easy_calendar/utils/tag_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ophelia tag palette keeps text contrast at WCAG AA', () {
    for (final background in tagPalette) {
      final foreground = onTagColor(background);
      expect(
        _contrastRatio(foreground, background),
        greaterThanOrEqualTo(4.5),
        reason:
            '${background.toARGB32().toRadixString(16)} selected '
            '${foreground.toARGB32().toRadixString(16)}',
      );
    }
  });

  test(
    'item accents prefer tags, then explicit and stable collection colors',
    () {
      const tagColor = 0xFF123456;
      const collectionColor = 0xFF654321;
      expect(
        colorForItemAccent(
          collectionId: 'work',
          tags: const ['focus'],
          tagColors: const {'focus': tagColor},
          collectionColors: const {'work': collectionColor},
        ).toARGB32(),
        tagColor,
      );
      expect(
        colorForItemAccent(
          collectionId: 'work',
          tags: const [],
          tagColors: const {},
          collectionColors: const {'work': collectionColor},
        ).toARGB32(),
        collectionColor,
      );
      final generated = colorForItemAccent(
        collectionId: 'personal',
        tags: const [],
        tagColors: const {},
        collectionColors: const {},
      );
      expect(
        colorForItemAccent(
          collectionId: 'personal',
          tags: const [],
          tagColors: const {},
          collectionColors: const {},
        ),
        generated,
      );
      expect(tagPalette, contains(generated));
    },
  );
}

double _contrastRatio(Color left, Color right) {
  final lighter = left.computeLuminance() > right.computeLuminance()
      ? left.computeLuminance()
      : right.computeLuminance();
  final darker = left.computeLuminance() > right.computeLuminance()
      ? right.computeLuminance()
      : left.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}

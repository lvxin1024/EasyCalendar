import 'package:flutter/material.dart';

import '../domain/item.dart';
import '../utils/tag_colors.dart';

List<String> tagsFromItems(Iterable<CalendarItem> items) {
  final tags = <String>{for (final item in items) ...item.tags};
  return tags.toList(growable: false)..sort();
}

bool matchesTagFilter(CalendarItem item, Set<String> selectedTags) =>
    selectedTags.isEmpty || item.tags.any(selectedTags.contains);

class TagFilterBar extends StatelessWidget {
  const TagFilterBar({
    super.key,
    required this.tags,
    required this.selectedTags,
    required this.colors,
    required this.onChanged,
  });

  final List<String> tags;
  final Set<String> selectedTags;
  final Map<String, int> colors;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty && selectedTags.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 20, right: 8),
            child: Icon(Icons.sell_outlined, size: 18),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tag in tags)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        selected: selectedTags.contains(tag),
                        label: Text(tag),
                        avatar: CircleAvatar(
                          radius: 6,
                          backgroundColor: colorForTag(tag, colors),
                        ),
                        onSelected: (selected) {
                          final next = {...selectedTags};
                          if (selected) {
                            next.add(tag);
                          } else {
                            next.remove(tag);
                          }
                          onChanged(next);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (selectedTags.isNotEmpty)
            IconButton(
              tooltip: '清除标签筛选',
              onPressed: () => onChanged(const {}),
              icon: const Icon(Icons.filter_alt_off_outlined),
            ),
        ],
      ),
    );
  }
}

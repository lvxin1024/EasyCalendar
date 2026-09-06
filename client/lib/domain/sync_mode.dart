enum SyncMode { local, cloud, group }

extension SyncModeCodec on SyncMode {
  String get wireName => name;

  static SyncMode? tryParse(String? value) {
    final normalized = value?.trim().toLowerCase();
    for (final mode in SyncMode.values) {
      if (mode.wireName == normalized) return mode;
    }
    return null;
  }
}

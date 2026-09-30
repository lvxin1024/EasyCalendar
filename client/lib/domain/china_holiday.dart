enum ChinaDayAdjustment { rest, work }

/// Returns only exceptions to the normal Monday-to-Friday working week.
/// Uses the supplied calendar date without converting its time zone.
///
/// State Council notices:
/// https://www.gov.cn/zhengce/content/202411/content_6986382.htm
/// https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm
/// ponytail: offline 2025-2026 data; extend after each official annual notice.
/// Dates outside the published data return null rather than being predicted.
ChinaDayAdjustment? chinaDayAdjustment(DateTime date) {
  final key = date.year * 10000 + date.month * 100 + date.day;
  if (date.weekday <= DateTime.friday && _restDays.contains(key)) {
    return ChinaDayAdjustment.rest;
  }
  if (date.weekday >= DateTime.saturday && _workDays.contains(key)) {
    return ChinaDayAdjustment.work;
  }
  return null;
}

const _restDays = <int>{
  20250101,
  20250128,
  20250129,
  20250130,
  20250131,
  20250203,
  20250204,
  20250404,
  20250501,
  20250502,
  20250505,
  20250602,
  20251001,
  20251002,
  20251003,
  20251006,
  20251007,
  20251008,
  20260101,
  20260102,
  20260216,
  20260217,
  20260218,
  20260219,
  20260220,
  20260223,
  20260406,
  20260501,
  20260504,
  20260505,
  20260619,
  20260925,
  20261001,
  20261002,
  20261005,
  20261006,
  20261007,
};

const _workDays = <int>{
  20250126,
  20250208,
  20250427,
  20250928,
  20251011,
  20260104,
  20260214,
  20260228,
  20260509,
  20260920,
  20261010,
};

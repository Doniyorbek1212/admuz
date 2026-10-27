import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/settings/business_settings.dart';
import 'package:sado/l10n/strings.dart';
import 'package:tdlib_ex/td_api.dart' as td;

void main() {
  const s = Strings('en');
  const day = 24 * 60;

  test('summarises open days and the first interval', () {
    final hours = td.BusinessOpeningHours(timeZoneId: 'Asia/Tashkent', openingHours: [
      for (var d = 0; d < 5; d++) td.BusinessOpeningHoursInterval(startMinute: d * day + 9 * 60, endMinute: d * day + 18 * 60),
    ]);
    expect(hoursSummary(hours, s), '5 days · 09:00–18:00');
  });

  test('shows round-the-clock and closed states', () {
    final allDay = td.BusinessOpeningHours(timeZoneId: 'UTC', openingHours: [
      for (var d = 0; d < 7; d++) td.BusinessOpeningHoursInterval(startMinute: d * day, endMinute: (d + 1) * day),
    ]);
    expect(hoursSummary(allDay, s), '7 days · Open 24 hours');
    expect(hoursSummary(const td.BusinessOpeningHours(timeZoneId: 'UTC', openingHours: []), s), 'Off');
  });
}

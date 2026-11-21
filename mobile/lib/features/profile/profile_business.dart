import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/strings.dart';
import '../../widgets/map_thumbnail.dart';

const _minutesPerDay = 24 * 60;

/// Open now, or not, from TDLib's countdowns (seconds; 0 = unknown); null when TDLib knows neither.
bool? isBusinessOpen(td.BusinessInfo info) {
  final (open, close) = (info.nextOpenIn, info.nextCloseIn);
  if (open <= 0 && close <= 0) return null;
  return close > 0 && (open <= 0 || close < open);
}

/// "2 kun", "3 soat", "15 daqiqa": [seconds] rounded in its largest unit, as Telegram shows it.
String _span(int seconds, Strings s) => seconds >= 86400
    ? s.t('biz_span_days', {'n': '${(seconds / 86400).round()}'})
    : seconds >= 3600
        ? s.t('biz_span_hours', {'n': '${(seconds / 3600).round()}'})
        : s.t('biz_span_minutes', {'n': '${math.max(1, (seconds / 60).round())}'});

/// Someone's business hours on their profile, as in Telegram: open or closed now and when that changes; the week on tap.
class BusinessHoursTile extends StatefulWidget {
  const BusinessHoursTile({super.key, required this.info});

  final td.BusinessInfo info;

  @override
  State<BusinessHoursTile> createState() => _BusinessHoursTileState();
}

class _BusinessHoursTileState extends State<BusinessHoursTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final open = isBusinessOpen(widget.info);
    final seconds = open == true ? widget.info.nextCloseIn : widget.info.nextOpenIn;
    final next = open == null || seconds <= 0 ? null : s.t(open ? 'biz_closes_in' : 'biz_opens_in', {'time': _span(seconds, s)});
    final hint = Theme.of(context).hintColor;
    return Column(children: [
      ListTile(
        leading: const Icon(Icons.schedule_rounded),
        title: Text(
          s.t(open == false ? 'biz_closed_now' : 'biz_open_now'),
          style: TextStyle(color: open == false ? const Color(0xFFE5484D) : const Color(0xFF2EAD5B), fontWeight: FontWeight.w600),
        ),
        subtitle: Text(s.t('biz_hours')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (next != null) Text(next, style: TextStyle(color: hint, fontSize: 13)),
          Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: hint),
        ]),
        onTap: () => setState(() => _expanded = !_expanded),
      ),
      if (_expanded)
        if (widget.info.localOpeningHours ?? widget.info.openingHours case final hours?) _Week(hours: hours),
    ]);
  }
}

/// Monday to Sunday with the hours of each day, in this device's time zone.
class _Week extends StatelessWidget {
  const _Week({required this.hours});

  final td.BusinessOpeningHours hours;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    String hm(int minute) => '${(minute % _minutesPerDay ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
    final byDay = <int, List<String>>{};
    for (final i in hours.openingHours) {
      final text = i.endMinute - i.startMinute >= _minutesPerDay ? s.t('biz_24h') : '${hm(i.startMinute)}–${hm(i.endMinute)}';
      byDay.putIfAbsent((i.startMinute ~/ _minutesPerDay) % 7, () => []).add(text);
    }
    // 1 January 2024 was a Monday; Telegram counts the week from Monday.
    final dayName = DateFormat.EEEE(s.locale);
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 10),
      child: Column(children: [
        for (var day = 0; day < 7; day++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(dayName.format(DateTime(2024, 1, 1 + day)))),
              Text(byDay[day]?.join(', ') ?? s.t('biz_closed_now'), style: TextStyle(color: Theme.of(context).hintColor)),
            ]),
          ),
      ]),
    );
  }
}

/// A business's address with a small map; opens the map app.
class BusinessLocationTile extends StatelessWidget {
  const BusinessLocationTile({super.key, required this.location});

  final td.BusinessLocation location;

  @override
  Widget build(BuildContext context) {
    final point = location.location;
    final query = point == null ? Uri.encodeQueryComponent(location.address) : '${point.latitude},${point.longitude}';
    return ListTile(
      leading: const Icon(Icons.location_on_outlined),
      title: Text(location.address, maxLines: 4, overflow: TextOverflow.ellipsis),
      subtitle: Text(context.t('biz_address')),
      trailing: point == null
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: MapThumbnail(latitude: point.latitude, longitude: point.longitude, width: 64, height: 64),
            ),
      onTap: () => launchUrl(Uri.parse('https://maps.google.com/?q=$query'), mode: LaunchMode.externalApplication),
    );
  }
}

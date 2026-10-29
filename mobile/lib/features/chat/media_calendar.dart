import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'message_content.dart' show bestPhotoSize;

/// Telegram's media calendar: months of the chat with a thumbnail on every day that has photos or videos.
/// Pops with the id of the tapped day's message so the chat can jump there.
class MediaCalendarScreen extends ConsumerStatefulWidget {
  const MediaCalendarScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<MediaCalendarScreen> createState() => _MediaCalendarScreenState();
}

class _MediaCalendarScreenState extends ConsumerState<MediaCalendarScreen> {
  static const _filter = td.SearchMessagesFilterPhotoAndVideo();

  /// Day key (yyyymmdd) → that day's media count and its first message.
  final Map<int, td.MessageCalendarDay> _days = {};
  /// Month key (yyyymm) → media count, estimated from sparse positions across the whole history.
  final Map<int, int> _monthTotals = {};
  int _total = 0;
  int _oldestId = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _loadMonthTotals();
  }

  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final calendar = await ref.read(accountProvider).send<td.MessageCalendar>(
            td.GetChatMessageCalendar(chatId: widget.chatId, topicId: null, filter: _filter, fromMessageId: _oldestId),
          );
      if (!mounted) return;
      setState(() {
        _total = calendar.totalCount;
        for (final day in calendar.days) {
          _days[_dayKey(DateTime.fromMillisecondsSinceEpoch(day.message.date * 1000))] = day;
        }
        final oldest = calendar.days.isEmpty ? 0 : calendar.days.map((d) => d.message.id).reduce((a, b) => a < b ? a : b);
        _done = calendar.days.isEmpty || oldest == _oldestId;
        _oldestId = oldest;
        _loading = false;
      });
    } on TdException catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  /// Sparse positions are evenly spread samples (position, date); consecutive samples bound how many media fall in each month.
  Future<void> _loadMonthTotals() async {
    try {
      final result = await ref.read(accountProvider).send<td.MessagePositions>(
            td.GetChatSparseMessagePositions(chatId: widget.chatId, filter: _filter, fromMessageId: 0, limit: 100, savedMessagesTopicId: 0),
          );
      final samples = [...result.positions]..sort((a, b) => a.position.compareTo(b.position));
      final totals = <int, int>{};
      for (var i = 0; i < samples.length; i++) {
        final next = i + 1 < samples.length ? samples[i + 1].position : result.totalCount;
        final date = DateTime.fromMillisecondsSinceEpoch(samples[i].date * 1000);
        final key = date.year * 100 + date.month;
        totals[key] = (totals[key] ?? 0) + (next - samples[i].position);
      }
      if (mounted) setState(() => _monthTotals.addAll(totals));
    } on TdException catch (error) {
      // Totals are a hint next to each month; the calendar works without them.
      debugPrint('sparse positions failed: $error');
    }
  }

  List<DateTime> get _months {
    if (_days.isEmpty) return const [];
    final keys = _days.keys.toList()..sort();
    final first = keys.first;
    final now = DateTime.now();
    final months = <DateTime>[];
    for (var m = DateTime(now.year, now.month); !m.isBefore(DateTime(first ~/ 10000, first ~/ 100 % 100)); m = DateTime(m.year, m.month - 1)) {
      months.add(m);
    }
    return months;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final months = _months;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('media_calendar')),
        bottom: _total > 0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s.count('media_count', _total), style: TextStyle(color: Theme.of(context).hintColor))),
              )
            : null,
      ),
      body: _error != null && _days.isEmpty
          ? Center(child: Text('$_error'))
          : _days.isEmpty
              ? Center(child: _loading ? const CircularProgressIndicator() : Text(s.t('media_calendar_empty')))
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 400) _loadMore();
                    return false;
                  },
                  child: ListView.builder(
                    itemCount: months.length + (_done ? 0 : 1),
                    itemBuilder: (context, i) => i == months.length
                        ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                        : _Month(month: months[i], days: _days, total: _monthTotals[months[i].year * 100 + months[i].month]),
                  ),
                ),
    );
  }
}

class _Month extends StatelessWidget {
  const _Month({required this.month, required this.days, this.total});

  final DateTime month;
  final Map<int, td.MessageCalendarDay> days;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Monday-first grid; leading blanks before the 1st.
    final lead = DateTime(month.year, month.month).weekday - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(DateFormat.yMMMM(s.locale).format(month), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          if (total != null && total! > 0) Text('≈ ${s.count('media_count', total!)}', style: TextStyle(color: theme.hintColor, fontSize: 13)),
        ]),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var d = 1; d <= daysInMonth; d++) _Day(day: d, entry: days[month.year * 10000 + month.month * 100 + d]),
          ],
        ),
      ]),
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({required this.day, this.entry});

  final int day;
  final td.MessageCalendarDay? entry;

  @override
  Widget build(BuildContext context) {
    final entry = this.entry;
    final label = Center(child: Text('$day', style: TextStyle(fontWeight: FontWeight.w600, color: entry == null ? Theme.of(context).hintColor : Colors.white)));
    if (entry == null) return label;
    final thumb = switch (entry.message.content) {
      td.MessagePhoto(:final photo) => bestPhotoSize(photo, target: 160)?.photo,
      td.MessageVideo(:final video) => video.thumbnail?.format is td.ThumbnailFormatMpeg4 ? null : video.thumbnail?.file,
      _ => null,
    };
    return GestureDetector(
      onTap: () => Navigator.pop(context, entry.message.id),
      // The count badge sits outside the round clip so it is never cut off.
      child: Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
        ClipOval(
          child: Stack(fit: StackFit.expand, children: [
            if (thumb != null) TdImage(file: thumb) else ColoredBox(color: Theme.of(context).colorScheme.primary),
            const ColoredBox(color: Colors.black26),
            label,
          ]),
        ),
        if (entry.totalCount > 1)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(8)),
              child: Text('${entry.totalCount}', style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }
}

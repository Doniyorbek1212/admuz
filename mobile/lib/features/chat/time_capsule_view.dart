import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'composer.dart' show pickScheduleTime;

/// "When should it open?": quick presets plus an exact date. Null when cancelled.
Future<DateTime?> pickCapsuleTime(BuildContext context) async {
  final s = context.s;
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
  final newYear = DateTime(now.year + 1);
  final presets = [
    (Icons.schedule_rounded, s.t('capsule_in_hour'), now.add(const Duration(hours: 1))),
    (Icons.wb_twilight_rounded, s.t('capsule_tomorrow'), tomorrow),
    (Icons.date_range_rounded, s.t('capsule_in_week'), now.add(const Duration(days: 7))),
    (Icons.celebration_rounded, s.t('capsule_new_year'), newYear),
  ];
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(s.t('capsule_when'), style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final (icon, label, at) in presets)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              subtitle: Text('${MaterialLocalizations.of(context).formatFullDate(at)}, ${TimeOfDay.fromDateTime(at).format(context)}'),
              onTap: () => Navigator.pop(context, at),
            ),
          ListTile(
            leading: const Icon(Icons.edit_calendar_rounded),
            title: Text(s.t('capsule_custom')),
            onTap: () => Navigator.pop(context, 'custom'),
          ),
        ],
      ),
    ),
  );
  if (choice is DateTime) return choice;
  if (choice != 'custom' || !context.mounted) return null;
  final at = await pickScheduleTime(context);
  return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at * 1000);
}

/// "12:03:09" or "3d 04:00:00" until [left] runs out.
String capsuleCountdown(Duration left) {
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(left.inHours % 24)}:${two(left.inMinutes % 60)}:${two(left.inSeconds % 60)}';
  return left.inDays > 0 ? '${left.inDays}d $clock' : clock;
}

/// A sealed capsule: frosted placeholder lines and a live countdown; calls [onOpen] when time is up.
class CapsuleSealedView extends StatefulWidget {
  const CapsuleSealedView({super.key, required this.unlockAt, required this.onOpen});

  final DateTime unlockAt;
  final VoidCallback onOpen;

  @override
  State<CapsuleSealedView> createState() => _CapsuleSealedViewState();
}

class _CapsuleSealedViewState extends State<CapsuleSealedView> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    if (!DateTime.now().isBefore(widget.unlockAt)) {
      _timer.cancel();
      widget.onOpen();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface;
    final left = widget.unlockAt.difference(DateTime.now());
    const ice = Color(0xFF7FC8F8);
    Widget line(double width) => Container(
          width: width,
          height: 10,
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(5)),
        );
    return Semantics(
      label: context.s.t('capsule_unlocks_in', {'time': capsuleCountdown(left.isNegative ? Duration.zero : left)}),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [ice.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0.10), ice.withValues(alpha: 0.22)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: ice.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line(190), line(150), line(110)]),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.ac_unit_rounded, size: 14, color: ice),
                  const SizedBox(width: 4),
                  Text(
                    context.s.t('capsule_unlocks_in', {'time': capsuleCountdown(left.isNegative ? Duration.zero : left)}),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ice, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

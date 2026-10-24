import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';

/// Kinds of cached media in the chart, with their colours (Telegram/aka order).
enum _Kind {
  documents(Color(0xFF3FC24D)),
  videos(Color(0xFF4FA6F0)),
  music(Color(0xFF9B6CE0)),
  photos(Color(0xFF3D8AD8)),
  voice(Color(0xFFE5486A)),
  other(Color(0xFFF5B830));

  const _Kind(this.color);
  final Color color;

  static _Kind of(td.FileType type) => switch (type) {
        td.FileTypeDocument() => documents,
        td.FileTypeVideo() || td.FileTypeVideoNote() || td.FileTypeAnimation() || td.FileTypeVideoStory() => videos,
        td.FileTypeAudio() => music,
        td.FileTypePhoto() || td.FileTypePhotoStory() => photos,
        td.FileTypeVoiceNote() => voice,
        _ => other,
      };
}

/// Cache sizes offered by the limit slider, in GB (0 = unlimited).
const _cacheLimits = [5, 16, 32, 0];

/// aka "Keshni tozalash vositasi": what the cache holds by kind and by chat, selective clearing and limits.
class StorageUsageScreen extends ConsumerStatefulWidget {
  const StorageUsageScreen({super.key});

  @override
  ConsumerState<StorageUsageScreen> createState() => _StorageUsageScreenState();
}

class _StorageUsageScreenState extends ConsumerState<StorageUsageScreen> {
  td.StorageStatistics? _stats;
  String? _error;
  bool _busy = false;
  final Set<_Kind> _selected = {..._Kind.values};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stats = await ref.read(accountProvider).storageStatsByChat();
      if (mounted) setState(() => _stats = stats);
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  /// Size and the concrete TDLib file types seen per kind.
  Map<_Kind, ({int size, List<td.FileType> types})> _byKind(td.StorageStatistics stats) {
    final sizes = <_Kind, int>{};
    final types = <_Kind, Map<String, td.FileType>>{};
    for (final chat in stats.byChat) {
      for (final entry in chat.byFileType) {
        final kind = _Kind.of(entry.fileType);
        sizes[kind] = (sizes[kind] ?? 0) + entry.size;
        types.putIfAbsent(kind, () => {})[entry.fileType.getConstructor()] = entry.fileType;
      }
    }
    return {for (final kind in _Kind.values) kind: (size: sizes[kind] ?? 0, types: types[kind]?.values.toList() ?? const [])};
  }

  Future<void> _clear(List<td.FileType> types, {List<int> chatIds = const [], required String what}) async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('clear_cache'), message: s.t('clear_cache_what', {'what': what}), destructive: true);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await guard(context, () => ref.read(accountProvider).clearCache(fileTypes: types, chatIds: chatIds));
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
    if (mounted) showToast(context, s.t('cache_cleared'));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final stats = _stats;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final account = ref.watch(accountProvider);
    final hint = Theme.of(context).hintColor;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('cache_cleaner'))),
      body: _error != null
          ? Center(child: Text(_error!))
          : stats == null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(s.t('storage_counting'), style: TextStyle(color: hint)),
                  ]),
                )
              : Builder(builder: (context) {
                  final byKind = _byKind(stats);
                  final total = max(1, stats.size);
                  final selectedSize = _selected.fold<int>(0, (sum, k) => sum + byKind[k]!.size);
                  final chats = [...stats.byChat.where((c) => c.size > 0)]..sort((a, b) => b.size.compareTo(a.size));
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: SizedBox.square(
                          dimension: 200,
                          child: CustomPaint(
                            painter: _DonutPainter([
                              for (final kind in _Kind.values)
                                if (_selected.contains(kind)) (byKind[kind]!.size / total, kind.color),
                            ]),
                            child: Center(
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Text(formatFileSize(stats.size).split(' ').first, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                                Text(formatFileSize(stats.size).split(' ').last, style: TextStyle(color: hint)),
                              ]),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(child: Text(s.t('storage_usage'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                      GroupHint(s.t('storage_cloud_hint')),
                      SettingsGroup(children: [
                        for (final kind in _Kind.values)
                          if (byKind[kind]!.size > 0)
                            CheckboxListTile(
                              value: _selected.contains(kind),
                              onChanged: (on) => setState(() => on! ? _selected.add(kind) : _selected.remove(kind)),
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: kind.color,
                              title: Text.rich(TextSpan(children: [
                                TextSpan(text: '${s.t('storage_kind_${kind.name}')}  '),
                                TextSpan(
                                  text: '${(byKind[kind]!.size * 100 / total).toStringAsFixed(byKind[kind]!.size * 100 < total ? 1 : 0)}%',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                                ),
                              ])),
                              secondary: Text(formatFileSize(byKind[kind]!.size), style: TextStyle(color: primary, fontSize: 15)),
                            ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: FilledButton(
                            onPressed: _busy || selectedSize == 0
                                ? null
                                : () => _clear(
                                      [for (final kind in _selected) ...byKind[kind]!.types],
                                      what: formatFileSize(selectedSize),
                                    ),
                            child: _busy
                                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text('${s.t('clear_cache')}  ${formatFileSize(selectedSize)}'),
                          ),
                        ),
                      ]),
                      SettingsGroup(title: s.t('keep_media'), children: [
                        RadioGroup<int>(
                          groupValue: settings.keepMediaDays,
                          onChanged: (v) {
                            if (v != null) notifier.setKeepMediaDays(v);
                          },
                          child: Column(children: [
                            for (final days in const [3, 7, 30, 0])
                              RadioListTile<int>(value: days, title: Text(days == 0 ? s.t('keep_forever') : s.t('keep_days', {'n': '$days'}))),
                          ]),
                        ),
                      ]),
                      SettingsGroup(title: s.t('max_cache'), children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              for (final gb in _cacheLimits)
                                Text(
                                  gb == 0 ? s.t('unlimited') : '$gb GB',
                                  style: TextStyle(color: settings.maxCacheGb == gb ? primary : hint),
                                ),
                            ],
                          ),
                        ),
                        Slider(
                          value: max(0, _cacheLimits.indexOf(settings.maxCacheGb)).toDouble(),
                          max: (_cacheLimits.length - 1).toDouble(),
                          divisions: _cacheLimits.length - 1,
                          onChanged: (v) => notifier.setMaxCacheGb(_cacheLimits[v.round()]),
                          onChangeEnd: (_) {
                            final current = ref.read(settingsProvider);
                            unawaited(account
                                .applyCacheLimits(keepDays: current.keepMediaDays, maxGb: current.maxCacheGb)
                                .then((_) => _load())
                                .catchError((Object error) => debugPrint('cache limit failed: $error')));
                          },
                        ),
                      ]),
                      GroupHint(s.t('max_cache_hint')),
                      if (chats.isNotEmpty)
                        SettingsGroup(title: s.t('storage_by_chat'), children: [
                          for (final chat in chats.take(50))
                            ListTile(
                              leading: chat.chatId == 0
                                  ? const CircleAvatar(child: Icon(Icons.folder_rounded))
                                  : ChatAvatar(chatId: chat.chatId, size: 42),
                              title: Text(
                                chat.chatId == 0
                                    ? s.t('storage_kind_other')
                                    : chat.chatId == account.myId
                                        ? s.t('saved_messages')
                                        : (account.chats[chat.chatId]?.title ?? '${chat.chatId}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(formatFileSize(chat.size), style: TextStyle(color: primary, fontSize: 15)),
                              onTap: chat.chatId == 0 || _busy
                                  ? null
                                  : () => _clear(
                                        const [],
                                        chatIds: [chat.chatId],
                                        what: '${account.chats[chat.chatId]?.title ?? ''} · ${formatFileSize(chat.size)}',
                                      ),
                            ),
                        ]),
                    ],
                  );
                }),
    );
  }
}

/// Ring chart: one arc per (fraction, colour), with small gaps between segments.
class _DonutPainter extends CustomPainter {
  _DonutPainter(this.segments);

  final List<(double, Color)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 34.0;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.shortestSide / 2 - stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final sum = segments.fold<double>(0, (a, s) => a + s.$1);
    if (sum <= 0) {
      canvas.drawArc(rect, 0, 2 * pi, false, paint..color = Colors.grey.withValues(alpha: 0.25));
      return;
    }
    var start = -pi / 2;
    for (final (fraction, color) in segments) {
      final sweep = fraction / sum * 2 * pi;
      if (sweep <= 0) continue;
      canvas.drawArc(rect, start, max(0.0, sweep - 0.03), false, paint..color = color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.segments != segments;
}

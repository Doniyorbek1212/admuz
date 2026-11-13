import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

/// Every top-up and purchase of the UZARO balance, newest first, by day; filter money in or spending.
class WalletHistoryScreen extends ConsumerStatefulWidget {
  const WalletHistoryScreen({super.key});

  @override
  ConsumerState<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends ConsumerState<WalletHistoryScreen> {
  static const _pageSize = 50;

  String _direction = 'all';
  final _items = <WalletEntry>[];
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    final direction = _direction;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _hasMore = true;
      }
    });
    try {
      final page = await ref.read(sadoApiProvider).walletHistory(offset: _items.length, limit: _pageSize, direction: direction);
      // The filter changed while this page loaded: its rows belong to the old filter.
      if (!mounted || direction != _direction) return;
      setState(() {
        _items.addAll(page.items);
        _hasMore = page.hasMore;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter(String direction) {
    if (direction == _direction) return;
    _direction = direction;
    _loading = false;
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final error = _error;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('wallet_history'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'all', label: Text(s.t('wallet_filter_all'))),
              ButtonSegment(value: 'in', label: Text(s.t('wallet_filter_in')), icon: const Icon(Icons.south_west_rounded, size: 18)),
              ButtonSegment(value: 'out', label: Text(s.t('wallet_filter_out')), icon: const Icon(Icons.north_east_rounded, size: 18)),
            ],
            selected: {_direction},
            onSelectionChanged: (picked) => _filter(picked.first),
          ),
        ),
        Expanded(
          child: _items.isEmpty && error != null
              ? EmptyState(
                  icon: Icons.wifi_off_rounded,
                  title: error is ApiException ? apiErrorText(context, error) : errorText(context, error),
                  action: FilledButton(onPressed: () => _load(reset: true), child: Text(s.t('retry'))),
                )
              : _items.isEmpty && !_loading
                  ? EmptyState(icon: Icons.receipt_long_rounded, title: s.t('wallet_history_empty'))
                  : RefreshIndicator(onRefresh: () => _load(reset: true), child: _list(context)),
        ),
      ]),
    );
  }

  Widget _list(BuildContext context) {
    final s = context.s;
    final day = DateFormat.yMMMMd(s.locale);
    // Rows grouped under a date header each.
    final groups = <String, List<WalletEntry>>{};
    for (final entry in _items) {
      final at = entry.createdAt;
      groups.putIfAbsent(at == null ? '' : day.format(at), () => []).add(entry);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_hasMore && !_loading && n.metrics.extentAfter < 400) _load();
        return false;
      },
      child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        for (final MapEntry(key: date, value: entries) in groups.entries)
          SettingsGroup(title: date, children: [for (final entry in entries) WalletEntryTile(entry: entry)]),
        if (_loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      ]),
    );
  }
}

/// One history row: what it was, when, and the amount (green for money in).
class WalletEntryTile extends ConsumerWidget {
  const WalletEntryTile({super.key, required this.entry, this.showDate = false});

  final WalletEntry entry;

  /// Date and time instead of just the time (the wallet's short list has no day headers).
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final theme = Theme.of(context);
    final at = entry.createdAt;
    final when = at == null ? null : (showDate ? DateFormat.yMMMd(s.locale).add_Hm() : DateFormat.Hm(s.locale)).format(at);
    final detail = _detail(s, ref);
    final income = entry.deltaUzs > 0;
    return ListTile(
      leading: _leading(),
      title: Text(_title(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([?detail, ?when].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        '${income ? '+' : '−'}${formatUzs(context, entry.deltaUzs.abs())}',
        style: TextStyle(color: income ? const Color(0xFF2EAD5B) : theme.colorScheme.onSurface, fontWeight: FontWeight.w700, fontSize: 15),
      ),
    );
  }

  Widget _leading() {
    if (entry.method == 'payme') {
      return Container(
        width: 36,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0x1F000000))),
        child: Image.asset('assets/payme.png', fit: BoxFit.contain),
      );
    }
    return TileIcon(_icon(), _color());
  }

  String _title(Strings s) => switch (entry.kind) {
        'topup' => s.t('wallet_kind_topup'),
        'refund' => s.t('wallet_kind_refund'),
        'bonus' => s.t('wallet_kind_bonus'),
        'gift' => entry.titleFor(s.locale) ?? s.t('gifts_title'),
        'badge' => s.t('uzaro_badge'),
        'username' => entry.title == null ? s.t('uzaro_username') : '@${entry.title}',
        _ => s.t('wallet_kind_adjust'),
      };

  /// What the line was about: how it was paid, or who got the gift.
  String? _detail(Strings s, WidgetRef ref) => switch (entry.kind) {
        'topup' || 'refund' => entry.method == 'payme' ? 'Payme' : s.t('wallet_method_card'),
        'gift' when entry.toSelf => s.t('wallet_gift_self'),
        'gift' => _recipientName(ref) ?? s.t('wallet_gift_sent'),
        'badge' => s.t('wallet_badge_bought'),
        'bonus' => s.t('wallet_bonus_from'),
        'username' => s.t('uzaro_username'),
        _ => null,
      };

  String? _recipientName(WidgetRef ref) {
    final id = entry.recipientId;
    if (id == null) return null;
    final user = id > 0 ? ref.watch(userProvider(id)) : null;
    if (user != null) return '${user.firstName} ${user.lastName}'.trim();
    return ref.watch(chatProvider(id))?.title;
  }

  IconData _icon() => switch (entry.kind) {
        'topup' => Icons.add_card_rounded,
        'refund' => Icons.undo_rounded,
        'bonus' => Icons.redeem_rounded,
        'gift' => entry.toSelf ? Icons.shopping_bag_rounded : Icons.card_giftcard_rounded,
        'badge' => Icons.verified_rounded,
        'username' => Icons.alternate_email_rounded,
        _ => Icons.tune_rounded,
      };

  Color _color() => switch (entry.kind) {
        'topup' => const Color(0xFF2EAD5B),
        'refund' => const Color(0xFFF5A623),
        'bonus' => const Color(0xFFD4A94E),
        'gift' => const Color(0xFFE5486A),
        'badge' => const Color(0xFF2E9BF0),
        'username' => const Color(0xFF7E57C2),
        _ => const Color(0xFF8E8E93),
      };
}

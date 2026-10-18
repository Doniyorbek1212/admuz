import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

/// Asks the admin for a rejection reason (3+ characters); null when cancelled.
Future<String?> askRejectReason(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t('admin_reject')),
      content: TextField(controller: controller, autofocus: true, maxLength: 256, decoration: InputDecoration(labelText: context.t('admin_reject_reason'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: () {
            final reason = controller.text.trim();
            if (reason.length >= 3) Navigator.pop(context, reason);
          },
          child: Text(context.t('admin_reject')),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Shows a receipt image fetched with the admin key, zoomable.
Future<void> showReceipt(BuildContext context, Future<Uint8List> Function() fetch) async {
  final bytes = await apiGuard<Uint8List>(context, fetch);
  if (bytes == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(clipBehavior: Clip.antiAlias, child: InteractiveViewer(maxScale: 5, child: Image.memory(bytes, fit: BoxFit.contain))),
  );
}

enum _ShopTab { pending, closing, live }

/// Shops waiting for approval (incl. paid slots with a receipt), close requests, and live shops.
class AdminShopsQueue extends ConsumerStatefulWidget {
  const AdminShopsQueue({super.key});

  @override
  ConsumerState<AdminShopsQueue> createState() => _AdminShopsQueueState();
}

class _AdminShopsQueueState extends ConsumerState<AdminShopsQueue> with AutomaticKeepAliveClientMixin {
  _ShopTab _tab = _ShopTab.pending;
  late Future<List<Shop>> _shops = _load();

  @override
  bool get wantKeepAlive => true;

  Future<List<Shop>> _load() => ref.read(sadoApiProvider).adminShops(status: switch (_tab) {
        _ShopTab.pending => 'pending',
        _ShopTab.closing => 'close_requested',
        _ShopTab.live => 'approved',
      });

  void _reload() => setState(() => _shops = _load());

  Future<void> _act(Future<void> Function() action, String doneKey) async {
    final done = await apiGuard(context, () async {
      await action();
      return true;
    });
    if (done == true && mounted) {
      showToast(context, context.t(doneKey));
      _reload();
    }
  }

  Future<void> _reject(Shop shop) async {
    final reason = await askRejectReason(context);
    if (reason == null || !mounted) return;
    await _act(() => ref.read(sadoApiProvider).adminRejectShop(shop.id, reason), 'admin_rejected');
  }

  Future<void> _close(Shop shop) async {
    final s = context.s;
    if (!await confirm(context, title: s.t('admin_close'), message: shop.name, destructive: true) || !mounted) return;
    await _act(() => ref.read(sadoApiProvider).adminCloseShop(shop.id), 'admin_closed');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: SegmentedButton<_ShopTab>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _ShopTab.pending, icon: const Icon(Icons.hourglass_top_rounded), label: Text(s.t('admin_pending'))),
              ButtonSegment(value: _ShopTab.closing, icon: const Icon(Icons.store_mall_directory_outlined), label: Text(s.t('admin_close_requests'))),
              ButtonSegment(value: _ShopTab.live, icon: const Icon(Icons.storefront_rounded), label: Text(s.t('admin_active'))),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() {
              _tab = v.first;
              _shops = _load();
            }),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Shop>>(
            future: _shops,
            builder: (context, snapshot) {
              final error = snapshot.error;
              if (error != null) return EmptyState(icon: Icons.cloud_off_rounded, title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'));
              final shops = snapshot.data;
              if (shops == null) return const Center(child: CircularProgressIndicator());
              if (shops.isEmpty) return EmptyState(icon: Icons.inbox_rounded, title: s.t('admin_no_pending'));
              return RefreshIndicator(
                onRefresh: () async {
                  _reload();
                  await _shops;
                },
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: shops.length,
                  itemBuilder: (context, i) => _shopCard(context, shops[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _shopCard(BuildContext context, Shop shop) {
    final s = context.s;
    final theme = Theme.of(context);
    final owner = shop.owner;
    final api = ref.read(sadoApiProvider);
    return SettingsGroup(children: [
      ListTile(
        leading: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox.square(dimension: 52, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
        title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          [shop.region, s.t('shop_products_n', {'n': '${shop.productCount ?? 0}'}), if (shop.phone.isNotEmpty) shop.phone, if (shop.telegram.isNotEmpty) '@${shop.telegram}'].join(' · '),
        ),
        trailing: shop.priceUzs > 0 ? Text(formatUzs(context, shop.priceUzs), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w800)) : null,
      ),
      if (owner != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text(
            s.t('admin_owner', {'name': [owner.name, if (owner.username.isNotEmpty) '@${owner.username}', if (owner.phone.isNotEmpty) '+${owner.phone}'].join(' · ')}),
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      if (shop.description.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 6), child: Text(shop.description, maxLines: 3, overflow: TextOverflow.ellipsis)),
      if (shop.closeRequested && shop.closeReason != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text(s.t('reject_reason', {'reason': shop.closeReason!}), style: TextStyle(color: theme.colorScheme.error)),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            if (shop.hasReceipt)
              TextButton.icon(onPressed: () => showReceipt(context, () => api.adminShopReceipt(shop.id)), icon: const Icon(Icons.receipt_long_rounded), label: Text(s.t('admin_payment'))),
            if (_tab == _ShopTab.pending) ...[
              OutlinedButton(onPressed: () => _reject(shop), style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error), child: Text(s.t('admin_reject'))),
              FilledButton(onPressed: () => _act(() => api.adminApproveShop(shop.id), 'admin_approved'), child: Text(s.t('admin_approve'))),
            ],
            if (_tab == _ShopTab.closing) ...[
              OutlinedButton(onPressed: () => _act(() => api.adminKeepShop(shop.id), 'admin_kept'), child: Text(s.t('admin_keep'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                onPressed: () => _close(shop),
                child: Text(s.t('admin_close')),
              ),
            ],
            if (_tab == _ShopTab.live)
              OutlinedButton(onPressed: () => _close(shop), style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error), child: Text(s.t('admin_close'))),
          ],
        ),
      ),
    ]);
  }
}

/// Customers with the profile they chose to share (name, username, phone), searchable.
class AdminUsersList extends ConsumerStatefulWidget {
  const AdminUsersList({super.key});

  @override
  ConsumerState<AdminUsersList> createState() => _AdminUsersListState();
}

class _AdminUsersListState extends ConsumerState<AdminUsersList> with AutomaticKeepAliveClientMixin {
  static const _debounce = Duration(milliseconds: 400);

  final List<AdminCustomer> _users = [];
  int _total = 0;
  String _query = '';
  bool _loading = false;
  Timer? _timer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final page = await apiGuard(context, () => ref.read(sadoApiProvider).adminUsers(query: _query, offset: reset ? 0 : _users.length));
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page == null) return;
      if (reset) _users.clear();
      _total = page.$1;
      _users.addAll(page.$2);
    });
  }

  void _search(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      _query = value.trim();
      _load(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            onChanged: _search,
            decoration: InputDecoration(
              hintText: s.t('admin_search_users'),
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: groupCardColor(context),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Align(alignment: Alignment.centerLeft, child: Text(s.t('admin_users_total', {'n': '$_total'}), style: TextStyle(color: Theme.of(context).hintColor))),
        ),
        Expanded(
          child: _users.isEmpty && _loading
              ? const Center(child: CircularProgressIndicator())
              : _users.isEmpty
                  ? EmptyState(icon: Icons.people_outline_rounded, title: s.t('admin_no_pending'))
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.extentAfter < 400 && _users.length < _total) _load();
                        return false;
                      },
                      child: RefreshIndicator(
                        onRefresh: () => _load(reset: true),
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: _users.length,
                          itemBuilder: (context, i) => _UserTile(user: _users[i]),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user});

  final AdminCustomer user;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final profile = user.profile;
    final name = profile?.name ?? '';
    final created = user.createdAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: groupCardColor(context),
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
            child: profile == null ? Icon(Icons.person_outline_rounded, color: theme.hintColor) : Text(initialsOf(name.isEmpty ? '?' : name)),
          ),
          title: Text(profile == null ? s.t('admin_anonymous') : (name.isEmpty ? '—' : name), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (profile != null && profile.phone.isNotEmpty) '+${profile.phone}',
              if (profile != null && profile.username.isNotEmpty) '@${profile.username}',
              s.t('admin_shops_n', {'n': '${user.shops}'}),
              s.t('admin_ads_n', {'n': '${user.ads}'}),
              if (user.platform.isNotEmpty) user.platform,
              if (created != null) DateFormat('dd.MM.yyyy').format(created),
            ].join(' · '),
          ),
          onLongPress: profile == null || profile.phone.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: '+${profile.phone}'));
                  showToast(context, s.t('copied'));
                },
        ),
      ),
    );
  }
}

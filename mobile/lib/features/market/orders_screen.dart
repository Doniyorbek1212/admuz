import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

const _statusColors = {
  OrderStatus.placed: Color(0xFF3D8BFF),
  OrderStatus.accepted: Color(0xFFF5A623),
  OrderStatus.shipped: Color(0xFF8E5CF7),
  OrderStatus.delivered: Color(0xFF2EAD5B),
  OrderStatus.cancelled: Color(0xFF8E8E93),
};

StatusChip _statusChip(OrderStatus status) => StatusChip(labelKey: 'order_status_${orderStatusName(status)}', color: _statusColors[status]!);

void _open(Uri uri) => unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));

Uri _tel(String phone) => Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));

/// Asks why the order is cancelled; null when the user backs out.
Future<String?> _askReason(BuildContext context, {required bool required}) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t('order_cancel_title')),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 256,
        decoration: InputDecoration(hintText: context.t(required ? 'order_cancel_reason' : 'order_cancel_reason_optional')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: () {
            final text = controller.text.trim();
            if (required && text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: Text(context.t('order_cancel')),
        ),
      ],
    ),
  );
  controller.dispose();
  return reason;
}

/// Loads a list of orders with pull-to-refresh, an error retry and an empty state.
class _OrderList extends StatefulWidget {
  const _OrderList({super.key, required this.load, required this.seller, required this.emptyTitle});

  final Future<List<Order>> Function() load;
  final bool seller;
  final String emptyTitle;

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList> {
  late Future<List<Order>> _orders = widget.load();

  Future<void> _reload() async {
    final next = widget.load();
    setState(() => _orders = next);
    await next.then((_) {}, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Order>>(
        future: _orders,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : context.t('err_GENERIC'),
              action: FilledButton(onPressed: _reload, child: Text(context.t('retry'))),
            );
          }
          final orders = snapshot.data;
          if (orders == null) return const Center(child: CircularProgressIndicator());
          return RefreshIndicator(
            onRefresh: _reload,
            child: orders.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    EmptyState(icon: Icons.receipt_long_outlined, title: widget.emptyTitle),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: orders.length,
                    itemBuilder: (context, i) => _OrderCard(
                      order: orders[i],
                      seller: widget.seller,
                      onTap: () async {
                        final changed = await Navigator.of(context)
                            .push<bool>(MaterialPageRoute(builder: (_) => OrderScreen(order: orders[i], seller: widget.seller)));
                        if (changed ?? false) unawaited(_reload());
                      },
                    ),
                  ),
          );
        },
      );
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.seller, required this.onTap});

  final Order order;
  final bool seller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final units = order.items.fold(0, (n, l) => n + l.quantity);
    return SettingsGroup(children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${s.t('order_number', {'n': order.number})} · ${seller ? order.name : order.shop.name}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              _statusChip(order.status),
            ]),
            if (order.createdAt case final date?)
              Text(DateFormat('dd.MM.yyyy HH:mm').format(date.toLocal()), style: TextStyle(fontSize: 12, color: theme.hintColor)),
            const SizedBox(height: 10),
            SizedBox(
              height: 56,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final line in order.items)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox.square(dimension: 56, child: NetImage(line.imageUrl, icon: Icons.shopping_bag_outlined)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Icon(order.pickup ? Icons.storefront_outlined : Icons.local_shipping_outlined, size: 16, color: theme.hintColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${s.t(order.pickup ? 'checkout_pickup' : 'checkout_delivery')} · ${s.t('checkout_units', {'n': '$units'})}',
                    style: TextStyle(color: theme.hintColor)),
              ),
              Text(formatUzs(context, order.totalUzs), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

/// The buyer's orders, newest first.
class MyOrdersScreen extends ConsumerWidget {
  const MyOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        backgroundColor: groupedBackground(context),
        appBar: AppBar(title: Text(context.t('orders_title'))),
        body: _OrderList(load: ref.read(sadoApiProvider).myOrders, seller: false, emptyTitle: context.t('orders_empty')),
      );
}

/// A shop's orders for its owner: the ones still to handle, and the finished ones.
class SellerOrdersScreen extends ConsumerWidget {
  const SellerOrdersScreen({super.key, required this.shop});

  final Shop shop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(sadoApiProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: groupedBackground(context),
        appBar: AppBar(
          title: Text(context.t('shop_orders')),
          bottom: TabBar(tabs: [Tab(text: context.t('orders_active')), Tab(text: context.t('orders_done'))]),
        ),
        body: TabBarView(children: [
          _OrderList(key: const ValueKey('active'), load: () => api.shopOrders(shop.id), seller: true, emptyTitle: context.t('orders_none_active')),
          _OrderList(key: const ValueKey('done'), load: () => api.shopOrders(shop.id, done: true), seller: true, emptyTitle: context.t('orders_empty')),
        ]),
      ),
    );
  }
}

/// One order: progress, items, delivery, contact, and what the viewer may do with it.
/// Pops true when the order changed.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.order, required this.seller});

  final Order order;
  final bool seller;

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  late Order _order = widget.order;
  bool _changed = false;
  bool _busy = false;

  Future<void> _run(Future<Order> Function() action) async {
    setState(() => _busy = true);
    final updated = await apiGuard(context, action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) {
        _order = updated;
        _changed = true;
      }
    });
  }

  Future<void> _cancel() async {
    final reason = await _askReason(context, required: widget.seller);
    if (reason == null || !mounted) return;
    final api = ref.read(sadoApiProvider);
    await _run(() => widget.seller ? api.setOrderStatus(_order.id, OrderStatus.cancelled, reason: reason) : api.cancelOrder(_order.id, reason));
  }

  Future<void> _advance(OrderStatus status) => _run(() => ref.read(sadoApiProvider).setOrderStatus(_order.id, status));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final order = _order;
    final steps = [OrderStatus.placed, OrderStatus.accepted, OrderStatus.shipped, OrderStatus.delivered];
    final forward = [for (final next in order.next) if (next != OrderStatus.cancelled) next];
    final canCancel = widget.seller ? order.next.contains(OrderStatus.cancelled) : order.status == OrderStatus.placed;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: groupedBackground(context),
        appBar: AppBar(title: Text(s.t('order_number', {'n': order.number}))),
        bottomNavigationBar: !widget.seller || forward.isEmpty
            ? null
            : Material(
                color: groupCardColor(context),
                elevation: 8,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: _busy ? null : () => _advance(forward.first),
                      child: Text(s.t('order_do_${orderStatusName(forward.first)}'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          SettingsGroup(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: order.status == OrderStatus.cancelled
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _statusChip(order.status),
                      if ((order.cancelReason ?? '').isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(s.t('order_cancel_why', {'reason': order.cancelReason!})),
                      ],
                    ])
                  : _Progress(steps: steps, reached: steps.indexOf(order.status), pickup: order.pickup),
            ),
          ]),
          SettingsGroup(title: s.t('checkout_summary'), children: [
            for (final line in order.items)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox.square(dimension: 48, child: NetImage(line.imageUrl, icon: Icons.shopping_bag_outlined)),
                ),
                title: Text(line.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${line.quantity} × ${formatUzs(context, line.priceUzs)}'),
                trailing: Text(formatUzs(context, line.priceUzs * line.quantity), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            const Divider(height: 1),
            ListTile(
              title: Text(s.t('cart_total'), style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: Text(formatUzs(context, order.totalUzs), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            ListTile(leading: const Icon(Icons.payments_outlined), title: Text(s.t('product_payment')), subtitle: Text(s.t('product_payment_hint'))),
          ]),
          SettingsGroup(title: s.t(order.pickup ? 'checkout_pickup' : 'checkout_delivery'), children: [
            ListTile(leading: const Icon(Icons.person_outline_rounded), title: Text(order.name), subtitle: Text(order.phone)),
            if (!order.pickup) ListTile(leading: const Icon(Icons.place_outlined), title: Text(order.address)),
            if (order.comment.isNotEmpty) ListTile(leading: const Icon(Icons.chat_bubble_outline_rounded), title: Text(order.comment)),
          ]),
          SettingsGroup(title: s.t(widget.seller ? 'order_buyer' : 'product_seller'), children: [
            if (widget.seller)
              ListTile(
                leading: const Icon(Icons.call_rounded),
                title: Text(s.t('shop_contact_call')),
                subtitle: Text(order.phone),
                onTap: () => _open(_tel(order.phone)),
              )
            else ...[
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox.square(dimension: 40, child: NetImage(order.shop.logoUrl, icon: Icons.storefront_rounded)),
                ),
                title: Text(order.shop.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(order.shop.region),
              ),
              if (order.shopPhone.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.call_rounded),
                  title: Text(s.t('shop_contact_call')),
                  subtitle: Text(order.shopPhone),
                  onTap: () => _open(_tel(order.shopPhone)),
                ),
              if (order.shopTelegram.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.send_rounded),
                  title: Text(s.t('shop_contact_tg')),
                  subtitle: Text('@${order.shopTelegram}'),
                  onTap: () => _open(Uri.https('t.me', '/${order.shopTelegram}')),
                ),
            ],
          ]),
          if (canCancel)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _cancel,
                icon: const Icon(Icons.close_rounded),
                label: Text(s.t('order_cancel')),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Placed → accepted → on the way → delivered, with the reached steps coloured.
class _Progress extends StatelessWidget {
  const _Progress({required this.steps, required this.reached, required this.pickup});

  final List<OrderStatus> steps;
  final int reached;
  final bool pickup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = _statusColors[OrderStatus.delivered]!;
    String label(OrderStatus step) => context.t(pickup && step == OrderStatus.shipped ? 'order_status_ready' : 'order_status_${orderStatusName(step)}');
    return Column(children: [
      for (final (i, step) in steps.indexed)
        Row(children: [
          Column(children: [
            Icon(i <= reached ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: i <= reached ? done : theme.disabledColor),
            if (i < steps.length - 1) Container(width: 2, height: 18, color: i < reached ? done : theme.dividerColor),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: i < steps.length - 1 ? 18 : 0),
              child: Text(label(step), style: TextStyle(fontWeight: i == reached ? FontWeight.w800 : FontWeight.w500, color: i <= reached ? null : theme.hintColor)),
            ),
          ),
        ]),
    ]);
  }
}

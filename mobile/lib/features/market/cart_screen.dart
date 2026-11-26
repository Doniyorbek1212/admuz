import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import 'market_state.dart';
import 'market_widgets.dart';
import 'orders_screen.dart';

/// The cart, one block per shop: each shop is checked out on its own (one order per seller).
class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// Current prices and stock from the server; offline, the cart stays as it was.
  Future<void> _refresh() async {
    final ids = [for (final l in ref.read(cartProvider)) l.product.id];
    if (ids.isEmpty) return;
    try {
      final fresh = await ref.read(sadoApiProvider).marketFeed(ids: ids);
      if (mounted) ref.read(cartProvider.notifier).refresh(fresh);
    } on ApiException catch (error) {
      debugPrint('cart not refreshed: ${error.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final lines = ref.watch(cartProvider);
    final shops = <String, List<CartLine>>{};
    for (final line in lines) {
      (shops[line.product.shopId] ??= []).add(line);
    }
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(lines.isEmpty ? s.t('cart_title') : '${s.t('cart_title')} · ${ref.watch(cartCountProvider)}'),
        actions: [
          IconButton(
            tooltip: s.t('orders_title'),
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MyOrdersScreen())),
          ),
        ],
      ),
      body: lines.isEmpty
          ? EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: s.t('cart_empty'),
              subtitle: s.t('cart_empty_hint'),
              action: FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cart_start'))),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [for (final MapEntry(:value) in shops.entries) _ShopBlock(lines: value)],
              ),
            ),
    );
  }
}

class _ShopBlock extends StatelessWidget {
  const _ShopBlock({required this.lines});

  final List<CartLine> lines;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final shop = lines.first.product.shop;
    final ready = [for (final l in lines) if (l.canOrder) l];
    final total = ready.fold(0, (sum, l) => sum + l.totalUzs);
    return SettingsGroup(children: [
      ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(dimension: 36, child: NetImage(shop?.logoUrl ?? '', icon: Icons.storefront_rounded)),
        ),
        title: Text(shop?.name ?? s.t('product_seller'), style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: shop == null ? null : Text(shop.region),
      ),
      for (final line in lines) _LineTile(line: line),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(s.t('cart_total'), style: const TextStyle(fontSize: 16))),
            Text(formatUzs(context, total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: ready.isEmpty || shop == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CheckoutScreen(shop: shop, lines: ready))),
            child: Text(s.t('cart_checkout', {'n': '${ready.fold(0, (n, l) => n + l.quantity)}'}), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    ]);
  }
}

class _LineTile extends ConsumerWidget {
  const _LineTile({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final theme = Theme.of(context);
    final product = line.product;
    final problem = !line.available
        ? s.t('cart_unavailable')
        : product.stock == 0
            ? s.t('out_of_stock')
            : product.stock < line.quantity
                ? s.t('cart_only_left', {'n': '${product.stock}'})
                : null;
    return InkWell(
      onTap: line.available ? () => openProduct(context, product) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: 84,
              child: Opacity(opacity: problem == null ? 1 : 0.45, child: NetImage(product.coverUrl, icon: Icons.shopping_bag_outlined)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(product.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(formatUzs(context, line.totalUzs), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (line.quantity > 1)
                Text(s.t('cart_each', {'sum': formatUzs(context, product.priceUzs)}), style: TextStyle(fontSize: 12, color: theme.hintColor)),
              if (problem != null) Text(problem, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(children: [
                if (line.available) QuantityStepper(product: product, dense: true),
                const Spacer(),
                FavoriteButton(productId: product.id, small: false),
                IconButton(
                  tooltip: s.t('cart_remove'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => ref.read(cartProvider.notifier).setQuantity(product.id, 0),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One shop's part of the cart: delivery or pickup, contact, address; paid to the seller on delivery.
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key, required this.shop, required this.lines});

  final ShopBrief shop;
  final List<CartLine> lines;

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  /// The buyer's last contact and address, so the next checkout is filled in.
  static const _lastKey = 'market.checkout';

  final _form = GlobalKey<FormState>();
  late final Map<String, dynamic> _last = _readLast();
  late final _name = TextEditingController(text: _last['name'] as String? ?? _myName());
  late final _phone = TextEditingController(text: _last['phone'] as String? ?? _myPhone());
  late final _address = TextEditingController(text: _last['address'] as String? ?? '');
  final _comment = TextEditingController();
  late bool _pickup = _last['pickup'] as bool? ?? false;
  bool _sending = false;

  Map<String, dynamic> _readLast() {
    final raw = ref.read(sharedPreferencesProvider).getString(_lastKey);
    if (raw == null) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return const {};
    }
  }

  String _myName() {
    final me = ref.read(meProvider);
    return me == null ? '' : '${me.firstName} ${me.lastName}'.trim();
  }

  String _myPhone() {
    final phone = ref.read(meProvider)?.phoneNumber ?? '';
    return phone.isEmpty ? '' : '+$phone';
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _comment]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _place() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _sending = true);
    final draft = OrderDraft(
      shopId: widget.shop.id,
      quantities: {for (final l in widget.lines) l.product.id: l.quantity},
      pickup: _pickup,
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      address: _address.text.trim(),
      comment: _comment.text.trim(),
    );
    final order = await apiGuard(context, () => ref.read(sadoApiProvider).placeOrder(draft));
    if (!mounted) return;
    setState(() => _sending = false);
    if (order == null) return;
    unawaited(ref.read(sharedPreferencesProvider).setString(
        _lastKey, jsonEncode({'name': draft.name, 'phone': draft.phone, 'address': draft.address, 'pickup': _pickup})));
    ref.read(cartProvider.notifier).removeAll(draft.quantities.keys);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, color: Color(0xFF13B88A), size: 56),
        title: Text(context.t('order_placed', {'n': order.number})),
        content: Text(context.t('order_placed_hint', {'shop': widget.shop.name})),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(context.t('ok')))],
      ),
    );
    if (!mounted) return;
    unawaited(Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const MyOrdersScreen())));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final total = widget.lines.fold(0, (sum, l) => sum + l.totalUzs);
    final units = widget.lines.fold(0, (n, l) => n + l.quantity);
    String? phoneCheck(String? value) =>
        RegExp(r'^\+?[0-9 ()-]{7,20}$').hasMatch((value ?? '').trim()) ? null : s.t('checkout_phone_invalid');
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('checkout_title'))),
      bottomNavigationBar: Material(
        color: groupCardColor(context),
        elevation: 8,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _sending ? null : _place,
              child: _sending
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : Text(s.t('checkout_place', {'sum': formatUzs(context, total)}), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          SettingsGroup(title: s.t('checkout_how'), children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, icon: const Icon(Icons.local_shipping_outlined), label: Text(s.t('checkout_delivery'))),
                  ButtonSegment(value: true, icon: const Icon(Icons.storefront_outlined), label: Text(s.t('checkout_pickup'))),
                ],
                selected: {_pickup},
                onSelectionChanged: (value) => setState(() => _pickup = value.first),
              ),
            ),
          ]),
          SettingsGroup(title: s.t('checkout_contact'), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(children: [
                TextFormField(
                  controller: _name,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: s.t('checkout_name'), prefixIcon: const Icon(Icons.person_outline_rounded)),
                  validator: (v) => (v ?? '').trim().length < 2 ? s.t('field_required') : null,
                ),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: s.t('checkout_phone'), prefixIcon: const Icon(Icons.phone_outlined)),
                  validator: phoneCheck,
                ),
                if (!_pickup)
                  TextFormField(
                    controller: _address,
                    maxLength: 300,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(labelText: s.t('checkout_address'), hintText: s.t('checkout_address_hint'), prefixIcon: const Icon(Icons.place_outlined)),
                    validator: (v) => (v ?? '').trim().length < 5 ? s.t('checkout_address_required') : null,
                  ),
                TextFormField(
                  controller: _comment,
                  maxLength: 500,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: s.t('checkout_comment'), prefixIcon: const Icon(Icons.chat_bubble_outline_rounded)),
                ),
              ]),
            ),
          ]),
          SettingsGroup(title: s.t('checkout_summary'), children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox.square(dimension: 40, child: NetImage(widget.shop.logoUrl, icon: Icons.storefront_rounded)),
              ),
              title: Text(widget.shop.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(s.t('checkout_units', {'n': '$units'})),
            ),
            for (final line in widget.lines)
              ListTile(
                dense: true,
                title: Text(line.product.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${line.quantity} × ${formatUzs(context, line.product.priceUzs)}'),
                trailing: Text(formatUzs(context, line.totalUzs), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            const Divider(height: 1),
            ListTile(
              title: Text(s.t('cart_total'), style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: Text(formatUzs(context, total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: Text(s.t('product_payment')),
              subtitle: Text(s.t('product_payment_hint')),
            ),
          ]),
        ]),
      ),
    );
  }
}

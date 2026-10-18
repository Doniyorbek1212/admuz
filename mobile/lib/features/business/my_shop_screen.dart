import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'business_widgets.dart';
import 'product_edit_screen.dart';
import 'shop_edit_screen.dart';
import 'warehouse_screen.dart';

typedef _Dashboard = (Shop shop, ShopStats stats, AdsConfig config);

/// Seller's dashboard for one shop: status and payment, accounting, products and warehouse.
class MyShopScreen extends ConsumerStatefulWidget {
  const MyShopScreen({super.key, required this.shopId});

  final String shopId;

  @override
  ConsumerState<MyShopScreen> createState() => _MyShopScreenState();
}

class _MyShopScreenState extends ConsumerState<MyShopScreen> {
  late Future<_Dashboard> _data = _load();
  bool _uploading = false;

  Future<_Dashboard> _load() async {
    final api = ref.read(sadoApiProvider);
    final results = await Future.wait([api.myShop(widget.shopId), api.shopStats(widget.shopId), api.adsConfig()]);
    return (results[0] as Shop, results[1] as ShopStats, results[2] as AdsConfig);
  }

  void _reload() => setState(() => _data = _load());

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _reload();
  }

  Future<void> _uploadReceipt(Shop shop) async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90, maxWidth: 2000);
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    final updated = await apiGuard(context, () => ref.read(sadoApiProvider).uploadShopReceipt(shop.id, file.path));
    if (!mounted) return;
    setState(() => _uploading = false);
    if (updated != null) {
      showToast(context, context.t('ad_receipt_sent'));
      _reload();
    }
  }

  Future<void> _requestClose(Shop shop) async {
    final s = context.s;
    final api = ref.read(sadoApiProvider);
    if (shop.closeRequested) {
      if (await apiGuard(context, () => api.cancelShopClose(shop.id)) != null) _reload();
      return;
    }
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('shop_close')),
        content: TextField(controller: controller, autofocus: true, maxLength: 256, decoration: InputDecoration(labelText: s.t('shop_close_reason'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= 3) Navigator.pop(context, text);
            },
            child: Text(s.t('shop_close')),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (reason == null || !mounted) return;
    if (await apiGuard(context, () => api.requestShopClose(shop.id, reason)) != null && mounted) {
      showToast(context, s.t('shop_close_sent'));
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('biz_my_shop'))),
      body: FutureBuilder<_Dashboard>(
        future: _data,
        builder: (context, snapshot) {
          final error = snapshot.error;
          if (error != null) {
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'),
              action: FilledButton(onPressed: _reload, child: Text(s.t('retry'))),
            );
          }
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final (shop, stats, config) = data;
          final needsPayment = shop.priceUzs > 0 && shop.status != ListingStatus.approved;
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _data;
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: [
                _header(context, shop),
                if (needsPayment)
                  SettingsGroup(title: s.t('shop_pay_title'), children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                      child: Text(s.t('shop_pay_text', {'price': formatUzs(context, shop.priceUzs)}), style: TextStyle(color: Theme.of(context).hintColor, height: 1.35)),
                    ),
                    CardPaymentBox(config: config, amountUzs: shop.priceUzs, hasReceipt: shop.hasReceipt, uploading: _uploading, onUpload: () => _uploadReceipt(shop)),
                  ]),
                _statsCard(context, stats),
                _productsCard(context, shop),
                SettingsGroup(children: [
                  ListTile(
                    leading: const TileIcon(Icons.warehouse_rounded, Color(0xFF13B88A)),
                    title: Text(s.t('warehouse')),
                    subtitle: Text(s.t('warehouse_history')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(WarehouseScreen(shop: shop)),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.edit_rounded, Color(0xFF3D8BFF)),
                    title: Text(s.t('biz_edit_shop')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(ShopEditScreen(shop: shop)),
                  ),
                  ListTile(
                    leading: TileIcon(shop.closeRequested ? Icons.undo_rounded : Icons.store_mall_directory_outlined, Theme.of(context).colorScheme.error),
                    title: Text(s.t(shop.closeRequested ? 'shop_close_cancel' : 'shop_close'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    subtitle: shop.closeRequested ? Text(s.t('shop_close_pending')) : null,
                    onTap: () => _requestClose(shop),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, Shop shop) {
    final s = context.s;
    final theme = Theme.of(context);
    return SettingsGroup(children: [
      ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        leading: ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox.square(dimension: 60, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
        title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (shop.status != null) StatusChip.listing(shop.status!),
            Text(shop.region),
          ]),
        ),
      ),
      if (shop.status == ListingStatus.rejected && shop.rejectReason != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(s.t('reject_reason', {'reason': shop.rejectReason!}), style: TextStyle(color: theme.colorScheme.error)),
        ),
    ]);
  }

  Widget _statsCard(BuildContext context, ShopStats stats) {
    final s = context.s;
    return SettingsGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.45,
          children: [
            StatTile(icon: Icons.inventory_2_rounded, color: const Color(0xFF3D8BFF), label: s.t('stat_products'), value: '${stats.activeProducts} / ${stats.products}'),
            StatTile(icon: Icons.warehouse_rounded, color: const Color(0xFF13B88A), label: s.t('stat_stock_units'), value: s.t('units', {'n': '${stats.stockUnits}'})),
            StatTile(icon: Icons.account_balance_wallet_rounded, color: const Color(0xFF8B6CFF), label: s.t('stat_stock_value'), value: formatUzs(context, stats.stockValueUzs)),
            StatTile(
              icon: Icons.trending_up_rounded,
              color: const Color(0xFFFF7A59),
              label: s.t('stat_revenue_30d'),
              value: formatUzs(context, stats.revenue30dUzs),
              caption: s.t('stat_units_sold', {'n': '${stats.unitsSold30d}'}),
            ),
          ],
        ),
      ),
      ListTile(
        dense: true,
        title: Text(s.t('stat_revenue_total')),
        subtitle: Text(s.t('stat_units_sold', {'n': '${stats.unitsSoldTotal}'})),
        trailing: Text(formatUzs(context, stats.revenueTotalUzs), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      if (stats.lowStock.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(s.t('low_stock'), style: const TextStyle(color: Color(0xFFE5486A), fontWeight: FontWeight.w700)),
        ),
        for (final (title, stock) in stats.lowStock)
          ListTile(
            dense: true,
            leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFF5A623)),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(stock == 0 ? s.t('out_of_stock') : s.t('units', {'n': '$stock'})),
          ),
      ],
    ]);
  }

  Widget _productsCard(BuildContext context, Shop shop) {
    final s = context.s;
    final theme = Theme.of(context);
    return SettingsGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
        child: Row(
          children: [
            Expanded(child: Text('${s.t('biz_products')} · ${shop.products.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
            TextButton.icon(onPressed: () => _open(ProductEditScreen(shopId: shop.id)), icon: const Icon(Icons.add_rounded), label: Text(s.t('biz_add_product'))),
          ],
        ),
      ),
      if (shop.products.isEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 14), child: Text(s.t('biz_no_products'), style: TextStyle(color: theme.hintColor)))
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: shop.products.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.7),
            itemBuilder: (context, i) {
              final product = shop.products[i];
              return _OwnerProductCard(product: product, onTap: () => _open(ProductEditScreen(shopId: shop.id, product: product)));
            },
          ),
        ),
    ]);
  }
}

class _OwnerProductCard extends StatelessWidget {
  const _OwnerProductCard({required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final out = product.stock == 0;
    return Material(
      color: theme.brightness == Brightness.dark ? const Color(0xFF222A35) : const Color(0xFFF6F7F9),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(product.coverUrl, icon: Icons.shopping_bag_outlined),
                  if (product.discountPercent > 0) Positioned(left: 8, top: 8, child: DiscountBadge(percent: product.discountPercent)),
                  if (!product.active)
                    const Positioned(right: 8, top: 8, child: CircleAvatar(radius: 14, backgroundColor: Colors.black54, child: Icon(Icons.visibility_off_rounded, size: 16, color: Colors.white))),
                  if (product.media.any((m) => m.isVideo))
                    const Positioned(right: 8, bottom: 8, child: CircleAvatar(radius: 14, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  PriceLine(product: product),
                  const SizedBox(height: 4),
                  Text(
                    out ? s.t('out_of_stock') : s.t('in_stock', {'n': '${product.stock}'}),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: out ? theme.colorScheme.error : const Color(0xFF13B88A)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

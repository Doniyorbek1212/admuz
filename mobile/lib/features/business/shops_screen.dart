import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../market/market_widgets.dart';
import 'business_widgets.dart';

/// "Online shops" of a region: approved shops, searchable by name.
class ShopsScreen extends ConsumerStatefulWidget {
  const ShopsScreen({super.key, required this.region});

  final String region;

  @override
  ConsumerState<ShopsScreen> createState() => _ShopsScreenState();
}

class _ShopsScreenState extends ConsumerState<ShopsScreen> {
  static const _debounce = Duration(milliseconds: 400);

  late Future<List<Shop>> _shops = _load('');
  Timer? _timer;

  Future<List<Shop>> _load(String query) => ref.read(sadoApiProvider).shops(widget.region, query: query);

  void _search(String query) {
    _timer?.cancel();
    _timer = Timer(_debounce, () => setState(() {
          _shops = _load(query.trim());
        }));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text('${s.t('shops_title')} · ${widget.region}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              onChanged: _search,
              decoration: InputDecoration(
                hintText: s.t('shop_search'),
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: groupCardColor(context),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Shop>>(
              future: _shops,
              builder: (context, snapshot) {
                final error = snapshot.error;
                if (error != null) {
                  return EmptyState(icon: Icons.cloud_off_rounded, title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'));
                }
                final shops = snapshot.data;
                if (shops == null) return const Center(child: CircularProgressIndicator());
                if (shops.isEmpty) return EmptyState(icon: Icons.storefront_outlined, title: s.t('shops_empty'));
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: shops.length,
                  itemBuilder: (context, i) => _ShopCard(shop: shops[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopCard extends StatelessWidget {
  const _ShopCard({required this.shop});

  final Shop shop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsGroup(children: [
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: ClipRRect(borderRadius: BorderRadius.circular(14), child: SizedBox.square(dimension: 56, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
        title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16.5)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (shop.description.isNotEmpty) Text(shop.description, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(context.t('shop_products_n', {'n': '${shop.productCount ?? 0}'}), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
          ],
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShopScreen(shopId: shop.id, title: shop.name))),
      ),
    ]);
  }
}

/// One shop for buyers: header with contacts, category filter and an Uzum-style product grid.
class ShopScreen extends ConsumerStatefulWidget {
  const ShopScreen({super.key, required this.shopId, required this.title});

  final String shopId;
  final String title;

  @override
  ConsumerState<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends ConsumerState<ShopScreen> {
  late final Future<Shop> _shop = ref.read(sadoApiProvider).shop(widget.shopId);
  String _category = '';

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(widget.title), actions: const [CartButton()]),
      body: FutureBuilder<Shop>(
        future: _shop,
        builder: (context, snapshot) {
          final error = snapshot.error;
          if (error != null) return EmptyState(icon: Icons.cloud_off_rounded, title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'));
          final shop = snapshot.data;
          if (shop == null) return const Center(child: CircularProgressIndicator());
          final categories = {for (final p in shop.products) if (p.category.isNotEmpty) p.category}.toList();
          final products = _category.isEmpty ? shop.products : shop.products.where((p) => p.category == _category).toList();
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context, shop)),
              if (categories.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 46,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(label: Text(s.t('all_products')), selected: _category.isEmpty, onSelected: (_) => setState(() => _category = '')),
                        ),
                        for (final c in categories)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(label: Text(s.t('cat_$c')), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
                          ),
                      ],
                    ),
                  ),
                ),
              if (products.isEmpty)
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32), child: Text(s.t('biz_no_products'), textAlign: TextAlign.center)))
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  sliver: SliverGrid.builder(
                    gridDelegate: marketGrid,
                    itemCount: products.length,
                    itemBuilder: (context, i) => MarketProductCard(product: products[i], shop: shop, showShop: false),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, Shop shop) {
    final s = context.s;
    final theme = Theme.of(context);
    void open(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Column(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(26), child: SizedBox.square(dimension: 92, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
          const SizedBox(height: 12),
          Text(shop.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${shop.region} · ${s.t('shop_products_n', {'n': '${shop.products.length}'})}', style: TextStyle(color: theme.hintColor)),
          if (shop.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(shop.description, textAlign: TextAlign.center, style: const TextStyle(height: 1.35)),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (shop.telegram.isNotEmpty)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => open(Uri.https('t.me', '/${shop.telegram}')),
                    icon: const Icon(Icons.send_rounded),
                    label: Text(s.t('shop_contact_tg')),
                  ),
                ),
              if (shop.telegram.isNotEmpty && shop.phone.isNotEmpty) const SizedBox(width: 10),
              if (shop.phone.isNotEmpty)
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => open(Uri(scheme: 'tel', path: shop.phone.replaceAll(RegExp(r'[^0-9+]'), ''))),
                    icon: const Icon(Icons.call_rounded),
                    label: Text(s.t('shop_contact_call')),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

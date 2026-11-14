import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/store_rules.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'business_widgets.dart';
import 'my_shop_screen.dart';
import 'shop_edit_screen.dart';

/// "Business profile": run your online shops. Paid hub ads live in their own AdsScreen.
class BusinessScreen extends ConsumerStatefulWidget {
  const BusinessScreen({super.key});

  @override
  ConsumerState<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends ConsumerState<BusinessScreen> {
  late Future<MyShops> _data = ref.read(sadoApiProvider).myShops();

  void _reload() => setState(() {
        _data = ref.read(sadoApiProvider).myShops();
      });

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _reload();
  }

  Future<void> _newShop() async {
    final created = await Navigator.of(context).push<Shop>(MaterialPageRoute(builder: (_) => const ShopEditScreen()));
    if (!mounted) return;
    if (created == null) return _reload();
    await _open(MyShopScreen(shopId: created.id));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('hub_business'))),
      body: FutureBuilder<MyShops>(
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
          final shops = snapshot.data;
          if (shops == null) return const Center(child: CircularProgressIndicator());
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _data;
            },
            child: ListView(
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 16),
              children: [_shopsSection(context, shops)],
            ),
          );
        },
      ),
    );
  }

  Widget _shopsSection(BuildContext context, MyShops my) {
    final s = context.s;
    final theme = Theme.of(context);
    return SettingsGroup(title: s.t('biz_my_shops'), children: [
      if (my.shops.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(s.t('biz_open_shop_hint'), style: TextStyle(color: theme.hintColor, height: 1.35)),
        ),
      for (final shop in my.shops)
        ListTile(
          leading: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox.square(dimension: 52, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
          title: Text(shop.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16.5)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (shop.status != null) StatusChip.listing(shop.status!),
                Text('${shop.region} · ${s.t('shop_products_n', {'n': '${shop.productCount ?? 0}'})}'),
              ],
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(MyShopScreen(shopId: shop.id)),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        child: FilledButton.icon(
          // iOS: further shops are paid outside the App Store, so only the free ones can be opened there.
          onPressed: storeBlocksExternalPayments && my.nextShopPriceUzs > 0 ? null : _newShop,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.add_business_rounded),
          label: Text(s.t(my.shops.isEmpty ? 'biz_open_shop' : 'biz_new_shop')),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
        child: Text(
          my.nextShopPriceUzs > 0 ? s.t('biz_new_shop_paid', {'price': formatUzs(context, my.nextShopPriceUzs)}) : s.t('biz_free_shops', {'n': '${my.freeLimit}'}),
          textAlign: TextAlign.center,
          style: TextStyle(color: my.nextShopPriceUzs > 0 ? const Color(0xFFF5A623) : theme.hintColor, fontSize: 13),
        ),
      ),
    ]);
  }
}

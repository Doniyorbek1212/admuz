import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/store_rules.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'ad_create_screen.dart';
import 'ad_payment_screen.dart';
import 'business_widgets.dart';
import 'my_shop_screen.dart';
import 'shop_edit_screen.dart';

/// "Business profile": place a paid hub ad and run your online shops.
class BusinessScreen extends ConsumerStatefulWidget {
  const BusinessScreen({super.key});

  @override
  ConsumerState<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends ConsumerState<BusinessScreen> {
  late Future<(MyShops, List<Ad>)> _data = _load();

  Future<(MyShops, List<Ad>)> _load() async {
    final api = ref.read(sadoApiProvider);
    final results = await Future.wait([api.myShops(), api.myAds()]);
    return (results[0] as MyShops, results[1] as List<Ad>);
  }

  void _reload() => setState(() => _data = _load());

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
      body: FutureBuilder<(MyShops, List<Ad>)>(
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
          final (shops, ads) = data;
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _data;
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (!storeBlocksExternalPayments) _AdCta(onTap: () => _open(const AdCreateScreen())),
                _shopsSection(context, shops),
                if (!storeBlocksExternalPayments || ads.isNotEmpty) _adsSection(context, ads),
              ],
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

  Widget _adsSection(BuildContext context, List<Ad> ads) {
    final s = context.s;
    final theme = Theme.of(context);
    return SettingsGroup(title: s.t('biz_my_ads'), children: [
      if (ads.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 12), child: Text(s.t('biz_no_ads'), style: TextStyle(color: theme.hintColor))),
      for (final ad in ads)
        ListTile(
          leading: ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 64, height: 44, child: AdMediaPreview(url: ad.mediaUrl, isVideo: ad.isVideo))),
          title: Text(ad.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [StatusChip.ad(ad), const SizedBox(width: 8), Flexible(child: Text(formatUzs(context, ad.priceUzs), overflow: TextOverflow.ellipsis))]),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(AdPaymentScreen(ad: ad)),
        ),
    ]);
  }
}

/// Gradient call-to-action at the top: "Place your ad".
class _AdCta extends StatelessWidget {
  const _AdCta({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFFF8A3D), Color(0xFFFF4D7A)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.t('biz_ad_cta_title'), style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text(s.t('biz_ad_cta_text'), style: TextStyle(color: Colors.white.withValues(alpha: 0.92), height: 1.3)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const CircleAvatar(radius: 26, backgroundColor: Colors.white24, child: Icon(Icons.campaign_rounded, color: Colors.white, size: 30)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

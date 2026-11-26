import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../business/product_screen.dart';
import 'cart_screen.dart';
import 'market_state.dart';

/// Icons of the product categories (server/app/market.py CATEGORIES) on the market's category row.
const categoryIcons = <String, IconData>{
  'electronics': Icons.devices_other_rounded,
  'phones': Icons.smartphone_rounded,
  'clothes': Icons.checkroom_rounded,
  'shoes': Icons.ice_skating_rounded,
  'beauty': Icons.face_retouching_natural_rounded,
  'home': Icons.chair_rounded,
  'kitchen': Icons.kitchen_rounded,
  'kids': Icons.child_care_rounded,
  'food': Icons.local_grocery_store_rounded,
  'flowers': Icons.local_florist_rounded,
  'sport': Icons.sports_soccer_rounded,
  'auto': Icons.directions_car_rounded,
  'books': Icons.menu_book_rounded,
  'health': Icons.health_and_safety_rounded,
  'other': Icons.category_rounded,
};

/// Red of prices with a discount, as on the shop cards.
const saleColor = Color(0xFFE5486A);

void openProduct(BuildContext context, Product product, {Shop? shop}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProductScreen(product: product, shop: shop)));

/// Adds one [product] to the cart, telling the user when its stock is already all in the cart.
void addToCart(BuildContext context, WidgetRef ref, Product product) {
  if (ref.read(cartProvider.notifier).add(product)) {
    unawaited(HapticFeedback.selectionClick());
  } else {
    showToast(context, context.t(product.stock == 0 ? 'out_of_stock' : 'cart_stock_limit'));
  }
}

/// The app bar's cart icon with the number of units in it.
class CartButton extends ConsumerWidget {
  const CartButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider);
    return IconButton(
      tooltip: context.t('cart_title'),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CartScreen())),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}

/// The heart on product photos; filled when the product is a favourite.
class FavoriteButton extends ConsumerWidget {
  const FavoriteButton({super.key, required this.productId, this.small = true});

  final String productId;
  final bool small;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(favoritesProvider).contains(productId);
    final icon = Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? saleColor : (small ? Colors.black87 : null), size: small ? 20 : 26);
    void toggle() {
      unawaited(HapticFeedback.selectionClick());
      ref.read(favoritesProvider.notifier).toggle(productId);
    }

    final label = context.t(liked ? 'fav_remove' : 'fav_add');
    if (!small) return IconButton(tooltip: label, onPressed: toggle, icon: icon);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.white.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: toggle, child: Padding(padding: const EdgeInsets.all(6), child: icon)),
      ),
    );
  }
}

/// − n + for a product in the cart; − at 1 takes it out.
class QuantityStepper extends ConsumerWidget {
  const QuantityStepper({super.key, required this.product, this.dense = false});

  final Product product;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quantity = ref.watch(cartProvider.select((lines) => lines.where((l) => l.product.id == product.id).firstOrNull?.quantity ?? 0));
    final size = dense ? 32.0 : 44.0;
    Widget button(IconData icon, String label, VoidCallback? onTap) => SizedBox.square(
          dimension: size,
          child: IconButton(
            tooltip: label,
            padding: EdgeInsets.zero,
            onPressed: onTap,
            icon: Icon(icon, size: dense ? 18 : 22),
          ),
        );
    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        button(quantity <= 1 ? Icons.delete_outline_rounded : Icons.remove_rounded, context.t('cart_less'),
            () => ref.read(cartProvider.notifier).setQuantity(product.id, quantity - 1)),
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: dense ? 22 : 32),
          child: Text('$quantity', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, fontSize: dense ? 14 : 16)),
        ),
        button(Icons.add_rounded, context.t('cart_more'), quantity >= product.stock ? null : () => addToCart(context, ref, product)),
      ]),
    );
  }
}

/// A product in the market's grids: photo with heart and discount, price, name, shop, and the cart button
/// (a stepper once it is in the cart).
class MarketProductCard extends ConsumerWidget {
  const MarketProductCard({super.key, required this.product, this.shop, this.showShop = true});

  final Product product;

  /// Set on a shop's own page, where the products come without their shop.
  final Shop? shop;
  final bool showShop;

  Product get _tagged => switch ((product.shop, shop)) {
        (null, final Shop shop?) => product.withShop(shop.brief),
        _ => product,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final theme = Theme.of(context);
    final out = product.stock == 0;
    final inCart = ref.watch(cartProvider.select((lines) => lines.any((l) => l.product.id == product.id)));
    final shopName = product.shop?.name ?? shop?.name ?? '';
    return Material(
      color: groupCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openProduct(context, _tagged, shop: shop),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              Opacity(opacity: out ? 0.45 : 1, child: NetImage(product.coverUrl, icon: Icons.shopping_bag_outlined)),
              if (product.discountPercent > 0) Positioned(left: 8, top: 8, child: DiscountBadge(percent: product.discountPercent)),
              Positioned(right: 6, top: 6, child: FavoriteButton(productId: product.id)),
              if (product.media.any((m) => m.isVideo))
                const Positioned(
                  right: 8,
                  bottom: 8,
                  child: CircleAvatar(radius: 13, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, size: 17, color: Colors.white)),
                ),
              if (out)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                    child: Text(s.t('out_of_stock'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PriceLine(product: product),
              const SizedBox(height: 3),
              Text(product.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.25)),
              if (showShop && shopName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.storefront_rounded, size: 13, color: theme.hintColor),
                  const SizedBox(width: 4),
                  Expanded(child: Text(shopName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: theme.hintColor))),
                ]),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: SizedBox(
              height: 36,
              child: inCart
                  ? QuantityStepper(product: _tagged, dense: true)
                  : FilledButton.icon(
                      onPressed: out ? null : () => addToCart(context, ref, _tagged),
                      style: FilledButton.styleFrom(padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                      label: Text(s.t('cart_add_short'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Grid layout of the market: two columns on phones, more on wide screens.
const marketGrid = SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 230, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.52);

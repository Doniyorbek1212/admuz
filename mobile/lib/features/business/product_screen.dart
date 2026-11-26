import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/settings_group.dart';
import '../market/cart_screen.dart';
import '../market/market_state.dart';
import '../market/market_widgets.dart';
import 'business_widgets.dart';
import 'shops_screen.dart';

/// Buyer's product page: swipeable photos/videos, price with discount, stock, delivery terms, description, the
/// seller with contacts, similar products, and the cart bar at the bottom.
class ProductScreen extends ConsumerStatefulWidget {
  const ProductScreen({super.key, required this.product, this.shop});

  final Product product;

  /// The full shop when opened from its page; otherwise it is loaded for the seller's contacts.
  final Shop? shop;

  @override
  ConsumerState<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends ConsumerState<ProductScreen> {
  int _page = 0;
  late final Future<Shop?> _shop = widget.shop != null ? Future.value(widget.shop) : _loadShop();
  late final Future<List<Product>> _similar = _loadSimilar();

  Product get _product => switch ((widget.product.shop, widget.shop)) {
        (null, final Shop shop?) => widget.product.withShop(shop.brief),
        _ => widget.product,
      };

  Future<Shop?> _loadShop() async {
    try {
      return await ref.read(sadoApiProvider).shop(widget.product.shopId);
    } on ApiException catch (error) {
      debugPrint('seller not loaded: ${error.code}');
      return null;
    }
  }

  Future<List<Product>> _loadSimilar() async {
    final region = widget.product.shop?.region ?? widget.shop?.region;
    if (region == null || widget.product.category.isEmpty) return const [];
    try {
      final found = await ref.read(sadoApiProvider).marketFeed(region: region, category: widget.product.category);
      return [for (final p in found) if (p.id != widget.product.id) p];
    } on ApiException catch (error) {
      debugPrint('similar products not loaded: ${error.code}');
      return const [];
    }
  }

  void _open(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final product = _product;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(product.shop?.name ?? ''),
        actions: [FavoriteButton(productId: product.id, small: false), const CartButton()],
      ),
      bottomNavigationBar: _CartBar(product: product),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _gallery(context, product),
          SettingsGroup(children: [_summary(context, product)]),
          SettingsGroup(children: [
            ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text(s.t('product_delivery')),
              subtitle: Text(s.t('product_delivery_hint')),
            ),
            ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: Text(s.t('product_payment')),
              subtitle: Text(s.t('product_payment_hint')),
            ),
          ]),
          if (product.description.isNotEmpty)
            SettingsGroup(title: s.t('product_details'), children: [
              Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 14), child: Text(product.description, style: const TextStyle(height: 1.45))),
            ]),
          FutureBuilder<Shop?>(future: _shop, builder: (context, snapshot) => _seller(context, product, snapshot.data)),
          FutureBuilder<List<Product>>(
            future: _similar,
            builder: (context, snapshot) {
              final similar = snapshot.data ?? const <Product>[];
              if (similar.isEmpty) return const SizedBox.shrink();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                  child: Text(s.t('product_similar'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                SizedBox(
                  height: 330,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: similar.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => SizedBox(width: 170, child: MarketProductCard(product: similar[i])),
                  ),
                ),
              ]);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _gallery(BuildContext context, Product product) {
    final theme = Theme.of(context);
    final media = product.media;
    return AspectRatio(
      aspectRatio: 1,
      child: ColoredBox(
        color: groupCardColor(context),
        child: Stack(children: [
          if (media.isEmpty)
            const Positioned.fill(child: NetImage('', icon: Icons.shopping_bag_outlined))
          else
            PageView.builder(
              itemCount: media.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => media[i].isVideo ? _ProductVideo(url: media[i].url) : NetImage(media[i].url, fit: BoxFit.contain),
            ),
          if (product.discountPercent > 0) Positioned(left: 12, top: 12, child: DiscountBadge(percent: product.discountPercent)),
          if (media.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < media.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(color: i == _page ? theme.colorScheme.primary : Colors.black26, borderRadius: BorderRadius.circular(3)),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _summary(BuildContext context, Product product) {
    final s = context.s;
    final theme = Theme.of(context);
    final out = product.stock == 0;
    final old = product.oldPriceUzs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PriceLine(product: product, big: true),
        if (product.discountPercent > 0 && old != null) ...[
          const SizedBox(height: 4),
          Text(s.t('product_you_save', {'sum': formatUzs(context, old - product.priceUzs)}),
              style: const TextStyle(color: Color(0xFF13B88A), fontWeight: FontWeight.w700)),
        ],
        const SizedBox(height: 8),
        Text(product.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.25)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(out ? Icons.remove_shopping_cart_rounded : Icons.inventory_2_rounded, size: 16, color: out ? theme.colorScheme.error : const Color(0xFF13B88A)),
            label: Text(out ? s.t('out_of_stock') : s.t('in_stock', {'n': '${product.stock}'})),
          ),
          if (product.category.isNotEmpty)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(categoryIcons[product.category] ?? Icons.category_rounded, size: 16),
              label: Text(s.t('cat_${product.category}')),
            ),
        ]),
      ]),
    );
  }

  Widget _seller(BuildContext context, Product product, Shop? shop) {
    final s = context.s;
    final brief = product.shop;
    if (brief == null && shop == null) return const SizedBox.shrink();
    final name = shop?.name ?? brief!.name;
    final logo = shop?.logoUrl ?? brief!.logoUrl;
    final region = shop?.region ?? brief!.region;
    final telegram = shop?.telegram ?? '';
    final phone = shop?.phone ?? '';
    return SettingsGroup(title: s.t('product_seller'), children: [
      ListTile(
        leading: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox.square(dimension: 46, child: NetImage(logo, icon: Icons.storefront_rounded))),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(region),
        trailing: const Icon(Icons.chevron_right_rounded),
        // From the shop's own page, going "into the shop" is going back.
        onTap: widget.shop != null
            ? () => Navigator.pop(context)
            : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShopScreen(shopId: product.shopId, title: name))),
      ),
      if (telegram.isNotEmpty || phone.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            if (telegram.isNotEmpty)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _open(Uri.https('t.me', '/$telegram')),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text(s.t('product_write_seller')),
                ),
              ),
            if (telegram.isNotEmpty && phone.isNotEmpty) const SizedBox(width: 10),
            if (phone.isNotEmpty)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _open(Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''))),
                  icon: const Icon(Icons.call_rounded, size: 18),
                  label: Text(s.t('shop_contact_call')),
                ),
              ),
          ]),
        ),
    ]);
  }
}

/// Bottom of the product page: "add to cart", or the stepper and "go to cart" once it is in.
class _CartBar extends ConsumerWidget {
  const _CartBar({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final inCart = ref.watch(cartProvider.select((lines) => lines.any((l) => l.product.id == product.id)));
    final out = product.stock == 0;
    const height = 52.0;
    return Material(
      color: groupCardColor(context),
      elevation: 8,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: inCart
              ? Row(children: [
                  QuantityStepper(product: product),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(height)),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CartScreen())),
                      child: Text(s.t('cart_go'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ])
              : FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(height)),
                  onPressed: out ? null : () => addToCart(context, ref, product),
                  icon: const Icon(Icons.add_shopping_cart_rounded),
                  label: Text(out ? s.t('out_of_stock') : s.t('cart_add'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
        ),
      ),
    );
  }
}

/// Product video with tap-to-play; muted until the user taps.
class _ProductVideo extends StatefulWidget {
  const _ProductVideo({required this.url});

  final String url;

  @override
  State<_ProductVideo> createState() => _ProductVideoState();
}

class _ProductVideoState extends State<_ProductVideo> {
  late final VideoPlayerController _controller = VideoPlayerController.networkUrl(Uri.parse(resolveMediaUrl(widget.url)));
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller.setLooping(true);
    _controller.initialize().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object error) {
      debugPrint('product video failed: $error');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || !isLoadableMedia(widget.url)) return AdMediaPreview(url: widget.url, isVideo: true);
    final value = _controller.value;
    if (!value.isInitialized) return const ColoredBox(color: Colors.black, child: Center(child: CircularProgressIndicator()));
    return GestureDetector(
      onTap: () => setState(() => value.isPlaying ? _controller.pause() : _controller.play()),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(alignment: Alignment.center, children: [
          AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(_controller)),
          if (!value.isPlaying) const CircleAvatar(radius: 30, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40)),
          Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(_controller, allowScrubbing: true)),
        ]),
      ),
    );
  }
}

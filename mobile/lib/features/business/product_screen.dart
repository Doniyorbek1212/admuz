import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/api/market_models.dart';
import '../../l10n/strings.dart';
import '../../widgets/settings_group.dart';
import 'business_widgets.dart';

/// Buyer's product page: swipeable photos/videos, price with discount, stock, description, seller contacts.
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.product, required this.shop});

  final Product product;
  final Shop shop;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  int _page = 0;

  void _open(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final product = widget.product;
    final shop = widget.shop;
    final media = product.media;
    final out = product.stock == 0;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(shop.name)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Row(
            children: [
              if (shop.telegram.isNotEmpty)
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    onPressed: () => _open(Uri.https('t.me', '/${shop.telegram}')),
                    icon: const Icon(Icons.send_rounded),
                    label: Text(s.t('product_write_seller')),
                  ),
                ),
              if (shop.telegram.isNotEmpty && shop.phone.isNotEmpty) const SizedBox(width: 10),
              if (shop.phone.isNotEmpty)
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    onPressed: () => _open(Uri(scheme: 'tel', path: shop.phone.replaceAll(RegExp(r'[^0-9+]'), ''))),
                    icon: const Icon(Icons.call_rounded),
                    label: Text(s.t('shop_contact_call')),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ColoredBox(
              color: groupCardColor(context),
              child: Stack(
                children: [
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
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < media.length; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: i == _page ? 16 : 6,
                              height: 6,
                              decoration: BoxDecoration(color: i == _page ? theme.colorScheme.primary : Colors.black26, borderRadius: BorderRadius.circular(3)),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          SettingsGroup(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PriceLine(product: product, big: true),
                  const SizedBox(height: 8),
                  Text(product.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.25)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(out ? Icons.remove_shopping_cart_rounded : Icons.inventory_2_rounded, size: 16, color: out ? theme.colorScheme.error : const Color(0xFF13B88A)),
                        label: Text(out ? s.t('out_of_stock') : s.t('in_stock', {'n': '${product.stock}'})),
                      ),
                      if (product.category.isNotEmpty) Chip(visualDensity: VisualDensity.compact, label: Text(s.t('cat_${product.category}'))),
                    ],
                  ),
                ],
              ),
            ),
          ]),
          if (product.description.isNotEmpty)
            SettingsGroup(title: s.t('product_details'), children: [
              Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 14), child: Text(product.description, style: const TextStyle(height: 1.45))),
            ]),
          SettingsGroup(children: [
            ListTile(
              leading: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox.square(dimension: 46, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded))),
              title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(shop.region),
            ),
          ]),
          const SizedBox(height: 16),
        ],
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
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(_controller)),
            if (!value.isPlaying) const CircleAvatar(radius: 30, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40)),
            Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(_controller, allowScrubbing: true)),
          ],
        ),
      ),
    );
  }
}

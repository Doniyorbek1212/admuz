import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../business/business_screen.dart';
import 'ad_banner_card.dart';
import 'hub_catalog.dart';

/// Approved paid ads for a region. Failures (offline, no server) just mean no ads.
final activeAdsProvider = FutureProvider.autoDispose.family<List<Ad>, String>((ref, region) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return const [];
  try {
    return await api.activeAds(region);
  } on ApiException catch (error) {
    debugPrint('active ads unavailable: $error');
    return const [];
  }
});

class _Promo {
  const _Promo({required this.titleKey, required this.textKey, required this.icon, required this.colors, required this.screen});

  final String titleKey;
  final String textKey;
  final IconData icon;
  final List<Color> colors;
  final Widget screen;
}

/// Shown only while a region has no paid ads, so the slot invites businesses to advertise.
const _promos = [
  _Promo(
    titleKey: 'banner_ad_title',
    textKey: 'banner_ad_text',
    icon: Icons.campaign_rounded,
    colors: [Color(0xFFFF8A3D), Color(0xFFFF4D7A)],
    screen: BusinessScreen(),
  ),
];

/// Auto-scrolling carousel at the top of the hub: paid ads for the selected region, or the advertise promo when there are none.
class HubBanners extends ConsumerStatefulWidget {
  const HubBanners({super.key});

  @override
  ConsumerState<HubBanners> createState() => _HubBannersState();
}

class _HubBannersState extends ConsumerState<HubBanners> {
  static const _interval = Duration(seconds: 6);

  final _controller = PageController();
  Timer? _timer;
  int _page = 0;
  int _count = _promos.length;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) {
      if (!_controller.hasClients || _count < 2) return;
      _controller.animateToPage((_page + 1) % _count, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _openAd(Ad ad) {
    if (ad.linkUrl.isNotEmpty) launchUrl(Uri.parse(ad.linkUrl), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final region = ref.watch(hubRegionProvider);
    final ads = ref.watch(activeAdsProvider(region)).value ?? const <Ad>[];
    final promos = ads.isEmpty ? _promos : const <_Promo>[];
    _count = ads.length + promos.length;
    if (_page >= _count) _page = 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: AspectRatio(
            aspectRatio: 2.2,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: PageView.builder(
                key: ValueKey('banners-$region-${ads.length}'),
                controller: _controller,
                itemCount: _count,
                onPageChanged: (page) => setState(() => _page = page),
                itemBuilder: (context, index) => index < ads.length
                    ? AdBannerCard(ad: ads[index], onTap: () => _openAd(ads[index]))
                    : _PromoCard(promo: promos[index - ads.length]),
              ),
            ),
          ),
        ),
        if (_count > 1)
          Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _count; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _page ? theme.colorScheme.primary : theme.hintColor.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _PromoCard extends StatelessWidget {
  const _PromoCard({required this.promo});

  final _Promo promo;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Material(
      child: Ink(
        decoration: BoxDecoration(gradient: LinearGradient(colors: promo.colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => promo.screen)),
          child: Stack(
            children: [
              // Soft decorative circles behind the icon.
              Positioned(right: -30, top: -30, child: _circle(150, 0.12)),
              Positioned(right: 40, bottom: -50, child: _circle(120, 0.10)),
              Positioned(
                right: 22,
                top: 0,
                bottom: 0,
                child: Center(child: Icon(promo.icon, size: 72, color: Colors.white.withValues(alpha: 0.92))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 120, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(s.t(promo.titleKey), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(
                      s.t(promo.textKey),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13.5, height: 1.3),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
                      child: Text(s.t('banner_more'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _circle(double size, double alpha) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alpha)),
      );
}

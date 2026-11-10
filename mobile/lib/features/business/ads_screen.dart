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

/// "Advertise": place a paid hub banner ad and follow your ads' payment and review status.
class AdsScreen extends ConsumerStatefulWidget {
  const AdsScreen({super.key});

  @override
  ConsumerState<AdsScreen> createState() => _AdsScreenState();
}

class _AdsScreenState extends ConsumerState<AdsScreen> {
  late Future<List<Ad>> _ads = ref.read(sadoApiProvider).myAds();

  void _reload() => setState(() => _ads = ref.read(sadoApiProvider).myAds());

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('hub_ads'))),
      body: FutureBuilder<List<Ad>>(
        future: _ads,
        builder: (context, snapshot) {
          final error = snapshot.error;
          if (error != null) {
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'),
              action: FilledButton(onPressed: _reload, child: Text(s.t('retry'))),
            );
          }
          final ads = snapshot.data;
          if (ads == null) return const Center(child: CircularProgressIndicator());
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _ads;
            },
            child: ListView(
              // Clears the system navigation bar / iPhone home indicator.
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 16),
              children: [
                // iOS: ads are paid outside the App Store, so only already placed ones are shown there.
                if (!storeBlocksExternalPayments) _AdCta(onTap: () => _open(const AdCreateScreen())),
                _adsSection(context, ads),
              ],
            ),
          );
        },
      ),
    );
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [StatusChip.ad(ad), const SizedBox(width: 8), Flexible(child: Text(formatUzs(context, ad.priceUzs), overflow: TextOverflow.ellipsis))]),
              if (ad.status == AdStatus.approved) ...[
                const SizedBox(height: 4),
                Text(
                  s.t('ad_stats', {'views': '${ad.views}', 'clicks': '${ad.clicks}'}),
                  style: TextStyle(color: theme.hintColor, fontSize: 12.5),
                ),
              ],
            ]),
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

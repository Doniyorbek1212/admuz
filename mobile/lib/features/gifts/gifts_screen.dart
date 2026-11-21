import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../contacts/contacts_screen.dart';
import 'gift_widgets.dart';
import 'my_gifts_screen.dart';
import 'topup_screen.dart';

/// Hub → Gifts: the UZARO balance, the gift shop (send to any contact) and the gifts this user received.
class GiftsScreen extends ConsumerStatefulWidget {
  const GiftsScreen({super.key});

  @override
  ConsumerState<GiftsScreen> createState() => _GiftsScreenState();
}

class _GiftsScreenState extends ConsumerState<GiftsScreen> {
  late Future<(List<GiftItem>, Wallet)> _shop = _loadShop();

  /// Bumped on every reload so the received list refetches too (a gift bought for oneself lands there).
  int _generation = 0;

  Future<(List<GiftItem>, Wallet)> _loadShop() async {
    final api = ref.read(sadoApiProvider);
    final results = await Future.wait([api.giftCatalog(), api.wallet()]);
    return (results[0] as List<GiftItem>, results[1] as Wallet);
  }

  void _reload() => setState(() {
        _shop = _loadShop();
        _generation++;
      });

  Future<void> _send([GiftItem? gift]) async {
    final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
    if (user == null || !mounted) return;
    final sent = await sendUzaroGift(context, recipientId: user.id, name: '${user.firstName} ${user.lastName}'.trim(), initial: gift);
    if (sent == true && mounted) _reload();
  }

  Future<void> _buyForMe([GiftItem? gift]) async {
    final bought = await buyUzaroGiftForMe(context, ref, initial: gift);
    if (bought == true && mounted) _reload();
  }

  /// A catalog gift: send it to a contact or keep it for the user's own profile.
  Future<void> _choose(GiftItem gift) async {
    final s = context.s;
    final forMe = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GiftImage(gift, size: 96),
          const SizedBox(height: 8),
          Text(gift.titleFor(s.locale), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(formatUzs(context, gift.priceUzs), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ListTile(
            leading: const TileIcon(Icons.send_rounded, Color(0xFF2E9BF0)),
            title: Text(s.t('gifts_send_friend')),
            onTap: () => Navigator.pop(context, false),
          ),
          ListTile(
            leading: const TileIcon(Icons.shopping_bag_rounded, Color(0xFFD4A94E)),
            title: Text(s.t('gifts_buy_for_me')),
            subtitle: Text(s.t('gifts_for_me_hint')),
            onTap: () => Navigator.pop(context, true),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (forMe == null || !mounted) return;
    forMe ? await _buyForMe(gift) : await _send(gift);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('gifts_title'))),
      body: FutureBuilder<(List<GiftItem>, Wallet)>(
        future: _shop,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return EmptyState(
              icon: Icons.wifi_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : errorText(context, error!),
              action: FilledButton(onPressed: _reload, child: Text(s.t('retry'))),
            );
          }
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final (gifts, wallet) = data;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: BalanceCard(
                  balanceUzs: wallet.balanceUzs,
                  action: FilledButton.tonalIcon(
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TopupScreen()));
                      if (mounted) _reload();
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: Text(s.t('gifts_topup_short')),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: WelcomeBonusBanner(bonusUzs: wallet.welcomeBonusUzs, onClaimed: _reload)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _send(),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), padding: const EdgeInsets.symmetric(horizontal: 10)),
                        icon: const Icon(Icons.card_giftcard_rounded),
                        label: Text(s.t('gifts_send'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _buyForMe(),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), padding: const EdgeInsets.symmetric(horizontal: 10)),
                        icon: const Icon(Icons.shopping_bag_rounded),
                        label: Text(s.t('gifts_buy_for_me'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(s.t('gifts_only_uzaro'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 13)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 116, childAspectRatio: 0.8, mainAxisSpacing: 8, crossAxisSpacing: 8),
                  itemCount: gifts.length,
                  itemBuilder: (context, i) => _ShopTile(gift: gifts[i], onTap: () => _choose(gifts[i])),
                ),
              ),
              SliverToBoxAdapter(child: ReceivedGifts(key: ValueKey(_generation))),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: Text(s.t('gifts_credits'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 11.5)),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _ShopTile extends StatelessWidget {
  const _ShopTile({required this.gift, required this.onTap});

  final GiftItem gift;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            Expanded(child: GiftImage(gift, size: 72)),
            Text(gift.titleFor(context.s.locale), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            Text(formatUzs(context, gift.priceUzs), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

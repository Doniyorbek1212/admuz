import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../contacts/contacts_screen.dart';
import 'gift_widgets.dart';
import 'topup_screen.dart';

/// Hub → Gifts: the UZARO balance, the gift shop (send to any contact) and the gifts this user received.
class GiftsScreen extends ConsumerStatefulWidget {
  const GiftsScreen({super.key});

  @override
  ConsumerState<GiftsScreen> createState() => _GiftsScreenState();
}

class _GiftsScreenState extends ConsumerState<GiftsScreen> {
  late Future<(List<GiftItem>, Wallet)> _shop = _loadShop();

  /// Received gifts and the "hide all" switch once this account is linked; null = not linked yet.
  late Future<(List<SentGift>, bool)?> _received = _loadReceived();

  Future<(List<GiftItem>, Wallet)> _loadShop() async {
    final api = ref.read(sadoApiProvider);
    final results = await Future.wait([api.giftCatalog(), api.wallet()]);
    return (results[0] as List<GiftItem>, results[1] as Wallet);
  }

  Future<(List<SentGift>, bool)?> _loadReceived() async {
    final api = ref.read(sadoApiProvider);
    if (await api.telegramId() != ref.read(accountProvider).myId) return null;
    return api.receivedGifts();
  }

  void _reload() => setState(() {
        _shop = _loadShop();
        _received = _loadReceived();
      });

  Future<void> _send([GiftItem? gift]) async {
    final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
    if (user == null || !mounted) return;
    final sent = await sendUzaroGift(context, user, initial: gift);
    if (sent == true && mounted) _reload();
  }

  Future<void> _link() async {
    if (await ensureGiftsLinked(context, ref) && mounted) _reload();
  }

  Future<void> _toggleHidden(SentGift gift) => _changeVisibility(() => ref.read(sadoApiProvider).setGiftHidden(gift.id, !gift.hidden));

  Future<void> _changeVisibility(Future<void> Function() change) async {
    final done = await apiGuard(context, () async {
      await change();
      return true;
    });
    if (done == true && mounted) {
      ref.invalidate(userGiftsProvider(ref.read(accountProvider).myId));
      _reload();
    }
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
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: FilledButton.icon(
                    onPressed: () => _send(),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    icon: const Icon(Icons.card_giftcard_rounded),
                    label: Text(s.t('gifts_send')),
                  ),
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
                  itemBuilder: (context, i) => _ShopTile(gift: gifts[i], onTap: () => _send(gifts[i])),
                ),
              ),
              SliverToBoxAdapter(child: _receivedSection(context)),
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

  Widget _receivedSection(BuildContext context) {
    final s = context.s;
    return FutureBuilder<(List<SentGift>, bool)?>(
      future: _received,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const SizedBox(height: 24);
        final data = snapshot.data;
        if (snapshot.hasError || data == null) {
          return SettingsGroup(title: s.t('gifts_received'), children: [
            ListTile(
              leading: const Icon(Icons.verified_user_rounded),
              title: Text(s.t('gifts_link_to_see')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _link,
            ),
          ]);
        }
        final (received, hideAll) = data;
        return SettingsGroup(title: s.t('gifts_received'), children: [
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_rounded),
            title: Text(s.t('gifts_hide_all')),
            subtitle: Text(s.t('gifts_hide_all_hint')),
            value: hideAll,
            onChanged: (hide) => _changeVisibility(() => ref.read(sadoApiProvider).setAllGiftsHidden(hide)),
          ),
          if (received.isEmpty) ListTile(title: Text(s.t('gifts_received_empty'))),
          for (final gift in received)
            ListTile(
              leading: GiftImage(gift.gift, size: 44),
              title: Text(gift.gift.titleFor(context.s.locale), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: gift.text.isEmpty ? null : Text(gift.text, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => showGiftDetails(context, gift),
              // While everything is hidden, single gifts have nothing to switch.
              trailing: IconButton(
                tooltip: s.t(gift.hidden ? 'gifts_show' : 'gifts_hide'),
                icon: Icon(gift.hidden || hideAll ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                onPressed: hideAll ? null : () => _toggleHidden(gift),
              ),
            ),
        ]);
      },
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

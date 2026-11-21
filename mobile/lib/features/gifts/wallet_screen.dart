import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/theme.dart' show brandGold;
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../profile/uzaro_username.dart';
import 'gift_widgets.dart' show buyUzaroGiftForMe;
import 'gifts_screen.dart';
import 'topup_screen.dart';
import 'wallet_history_screen.dart';
import 'uzaro_badge.dart' show showUzaroBadgeSheet;

/// The UZARO balance with its history; refreshed after every purchase or top-up.
final walletProvider = FutureProvider.autoDispose<Wallet>((ref) => ref.watch(sadoApiProvider).wallet());

/// Profile → Wallet: the UZARO balance, top-up, everything it buys (gifts, the badge, a short @name) and the history.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final wallet = ref.watch(walletProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('wallet'))),
      body: switch (wallet) {
        AsyncValue(:final value?) => RefreshIndicator(
            onRefresh: () => ref.refresh(walletProvider.future),
            child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              BalanceCard(
                balanceUzs: value.balanceUzs,
                action: FilledButton.tonalIcon(
                  onPressed: () => _open(context, ref, () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TopupScreen()))),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(s.t('gifts_topup_short')),
                ),
              ),
              WelcomeBonusBanner(bonusUzs: value.welcomeBonusUzs, onClaimed: () => ref.invalidate(walletProvider)),
              _shop(context, ref),
              _history(context, value),
            ]),
          ),
        AsyncError(:final error) => EmptyState(
            icon: Icons.wifi_off_rounded,
            title: error is ApiException ? apiErrorText(context, error) : errorText(context, error),
            action: FilledButton(onPressed: () => ref.invalidate(walletProvider), child: Text(s.t('retry'))),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  /// Runs a purchase flow, then reloads the balance and history.
  static Future<void> _open(BuildContext context, WidgetRef ref, Future<void> Function() flow) async {
    await flow();
    if (context.mounted) ref.invalidate(walletProvider);
  }

  Widget _shop(BuildContext context, WidgetRef ref) {
    final s = context.s;
    Widget row(IconData icon, Color color, String title, String subtitle, Future<void> Function() flow) => ListTile(
          leading: TileIcon(icon, color),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(context, ref, flow),
        );
    return SettingsGroup(title: s.t('wallet_shop'), children: [
      row(Icons.card_giftcard_rounded, const Color(0xFFE5486A), s.t('gifts_send'), s.t('wallet_gifts_sub'),
          () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GiftsScreen()))),
      row(Icons.shopping_bag_rounded, brandGold, s.t('gifts_buy_for_me'), s.t('gifts_for_me_hint'), () => buyUzaroGiftForMe(context, ref)),
      row(Icons.verified_rounded, const Color(0xFF2E9BF0), s.t('uzaro_badge'), s.t('wallet_badge_sub'), () => showUzaroBadgeSheet(context, ref)),
      row(Icons.alternate_email_rounded, const Color(0xFF7E57C2), s.t('uzaro_username'), s.t('wallet_username_sub'), () async {
        final current = await ref.read(myUzaroNameProvider.future).catchError((Object _) => null);
        if (!context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UzaroUsernameScreen(current: current)));
        ref.invalidate(myUzaroNameProvider);
      }),
    ]);
  }

  Widget _history(BuildContext context, Wallet wallet) {
    final s = context.s;
    final theme = Theme.of(context);
    final pending = [for (final t in wallet.topups) if (t.status == 'pending') t];
    return SettingsGroup(title: s.t('wallet_history'), children: [
      for (final topup in pending)
        ListTile(
          leading: const TileIcon(Icons.hourglass_top_rounded, Color(0xFF8E8E93)),
          title: Text(s.t('wallet_topup_pending')),
          trailing: Text('+${formatUzs(context, topup.amountUzs)}', style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w700)),
        ),
      if (wallet.entries.isEmpty && pending.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Text(s.t('wallet_history_empty'), style: TextStyle(color: theme.hintColor)),
        ),
      for (final entry in wallet.entries) WalletEntryTile(entry: entry, showDate: true),
      if (wallet.entries.isNotEmpty)
        ListTile(
          title: Text(s.t('wallet_history_all'), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
          trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.primary),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WalletHistoryScreen())),
        ),
    ]);
  }
}

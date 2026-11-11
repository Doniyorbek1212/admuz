import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/api/id_batcher.dart';
import '../../core/api/sado_api.dart';
import '../../core/theme.dart' show brandGold;
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart';
import '../business/business_widgets.dart';
import 'gift_widgets.dart' show ensureGiftsLinked;
import 'topup_screen.dart';

final _badgeLoaderProvider = Provider((ref) => IdBatcher<int>(ref.watch(sadoApiProvider).badgesOf));

/// UZARO badge of a Telegram user: custom emoji id, 0 for the checkmark, null for none.
// shortcut: cached for the session, so someone else's new badge shows after a restart; the user's own purchase
// invalidates theirs right away.
final uzaroBadgeProvider = FutureProvider.family<int?, int>((ref, userId) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return null;
  return ref.watch(_badgeLoaderProvider).load(userId);
});

/// The paid UZARO badge after a name: a gold checkmark (not Telegram's blue verification) or a custom emoji.
class UzaroBadge extends ConsumerWidget {
  const UzaroBadge({super.key, required this.userId, this.size = 18});

  final int userId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emojiId = ref.watch(uzaroBadgeProvider(userId)).value;
    if (emojiId == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(message: context.t('uzaro_badge'), child: _BadgeIcon(emojiId: emojiId, size: size)),
    );
  }
}

/// What follows a person's name in headers: their Telegram Premium emoji status, then their UZARO badge.
/// Nothing for groups, channels' own badges aside, or Saved Messages.
class NameBadges extends ConsumerWidget {
  const NameBadges({super.key, required this.chat, this.size = 18});

  final td.Chat chat;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final user = account.privateUser(chat);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      EmojiStatusBadge(status: chat.emojiStatus, size: size),
      if (user != null && !account.isSavedMessages(chat)) UzaroBadge(userId: user.id, size: size),
    ]);
  }
}

class _BadgeIcon extends StatelessWidget {
  const _BadgeIcon({required this.emojiId, required this.size});

  final int emojiId;
  final double size;

  @override
  Widget build(BuildContext context) =>
      emojiId == 0 ? Icon(Icons.verified_rounded, size: size, color: brandGold) : CustomEmojiView(id: emojiId, size: size);
}

/// Buy, extend or restyle the user's own UZARO badge. Needs the Telegram account proven to the server first.
Future<void> showUzaroBadgeSheet(BuildContext context, WidgetRef ref) async {
  if (!await ensureGiftsLinked(context, ref) || !context.mounted) return;
  await showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true, builder: (_) => const _BadgeSheet());
}

class _BadgeSheet extends ConsumerStatefulWidget {
  const _BadgeSheet();

  @override
  ConsumerState<_BadgeSheet> createState() => _BadgeSheetState();
}

class _BadgeSheetState extends ConsumerState<_BadgeSheet> {
  late Future<(BadgeOffer, List<int>)> _data = _load();
  int? _picked;
  bool _busy = false;

  Future<(BadgeOffer, List<int>)> _load() async {
    final account = ref.read(accountProvider);
    final offer = ref.read(sadoApiProvider).badgeOffer();
    // The emoji Telegram offers everyone as statuses; any of them can be the UZARO badge, Premium or not.
    var emoji = <int>[];
    try {
      final lists = await Future.wait([
        account.send<td.EmojiStatusCustomEmojis>(const td.GetThemedEmojiStatuses()),
        account.send<td.EmojiStatusCustomEmojis>(const td.GetDefaultEmojiStatuses()),
      ]);
      emoji = {for (final list in lists) ...list.customEmojiIds}.toList();
    } on TdException catch (error) {
      debugPrint('badge emoji unavailable: $error');
    }
    return (await offer, emoji);
  }

  Future<void> _run(Future<void> Function() action, String doneKey) async {
    setState(() => _busy = true);
    final ok = await apiGuard(context, () async {
      await action();
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok != true) return;
    ref.invalidate(uzaroBadgeProvider(ref.read(accountProvider).myId));
    showToast(context, context.t(doneKey));
    Navigator.pop(context);
  }

  Future<void> _topUp() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TopupScreen()));
    if (mounted) {
      setState(() {
        _data = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: FutureBuilder<(BadgeOffer, List<int>)>(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return EmptyState(
                icon: Icons.wifi_off_rounded,
                title: error is ApiException ? apiErrorText(context, error) : errorText(context, error!),
                action: FilledButton(onPressed: () => setState(() {
                  _data = _load();
                }), child: Text(s.t('retry'))),
              );
            }
            final data = snapshot.data;
            if (data == null) return const Center(child: CircularProgressIndicator());
            return _content(context, data.$1, data.$2);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, BadgeOffer offer, List<int> emoji) {
    final s = context.s;
    final theme = Theme.of(context);
    final active = offer.emojiId;
    final picked = _picked ?? active ?? 0;
    final price = formatUzs(context, offer.priceUzs);
    final enough = offer.balanceUzs >= offer.priceUzs;
    Widget choice(int id) => InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _picked = id),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: id == picked ? brandGold : Colors.transparent, width: 2),
            ),
            padding: const EdgeInsets.all(6),
            child: _BadgeIcon(emojiId: id, size: 30),
          ),
        );
    return Column(children: [
      Text(s.t('uzaro_badge'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
        child: Text(
          active == null
              ? s.t('uzaro_badge_hint')
              : s.t('uzaro_badge_until', {'date': DateFormat.yMMMd(s.locale).format(offer.expiresAt!)}),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.hintColor),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: GridView.count(
          crossAxisCount: 6,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [choice(0), for (final id in emoji) choice(id)],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${s.t('gifts_balance')}: ${formatUzs(context, offer.balanceUzs)}', textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor)),
          const SizedBox(height: 8),
          if (active != null && picked != active)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: _busy ? null : () => _run(() => ref.read(sadoApiProvider).changeBadge(picked), 'uzaro_badge_changed'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text(s.t('uzaro_badge_change')),
              ),
            ),
          if (offer.priceUzs > 0)
            FilledButton.icon(
              onPressed: _busy ? null : (enough ? () => _run(() => ref.read(sadoApiProvider).buyBadge(picked), 'uzaro_badge_bought') : _topUp),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              icon: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(enough ? Icons.verified_rounded : Icons.account_balance_wallet_rounded),
              label: Text(!enough
                  ? s.t('gifts_topup')
                  : s.t(active == null ? 'uzaro_badge_buy' : 'uzaro_badge_extend', {'price': price, 'n': '${offer.days}'})),
            ),
          const SizedBox(height: 6),
          Text(s.t('uzaro_badge_premium_note'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
        ]),
      ),
    ]);
  }
}

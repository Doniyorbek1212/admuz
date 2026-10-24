import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../chat/composer_panels.dart';
import 'privacy_screen.dart';

/// Limits Telegram raises with Premium, as reported by the server.
const _limitTypes = <(td.PremiumLimitType, String)>[
  (td.PremiumLimitTypeChatFolderCount(), 'limit_folders'),
  (td.PremiumLimitTypePinnedChatCount(), 'limit_pinned_chats'),
  (td.PremiumLimitTypeCreatedPublicChatCount(), 'limit_public_links'),
  (td.PremiumLimitTypeSupergroupCount(), 'limit_groups'),
  (td.PremiumLimitTypeFavoriteStickerCount(), 'limit_favorite_stickers'),
  (td.PremiumLimitTypeSavedAnimationCount(), 'limit_saved_gifs'),
  (td.PremiumLimitTypeBioLength(), 'limit_bio'),
  (td.PremiumLimitTypeCaptionLength(), 'limit_caption'),
];

final _premiumProvider = FutureProvider.autoDispose<(td.PremiumState, List<td.PremiumLimit>)>((ref) async {
  final account = ref.watch(accountProvider);
  final state = await account.send<td.PremiumState>(const td.GetPremiumState());
  final limits = await Future.wait([for (final (type, _) in _limitTypes) account.send<td.PremiumLimit>(td.GetPremiumLimit(limitType: type))]);
  return (state, limits);
});

/// Server text about the user's Premium state, the Premium limits table and gift-code redemption.
class PremiumServerSection extends ConsumerWidget {
  const PremiumServerSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final data = ref.watch(_premiumProvider).value;
    final account = ref.watch(accountProvider);
    return Column(
      children: [
        if (data != null && data.$1.state.text.isNotEmpty) GroupHint(data.$1.state.text),
        if (data != null)
          SettingsGroup(title: s.t('premium_limits'), children: [
            for (final (i, limit) in data.$2.indexed)
              ListTile(
                dense: true,
                title: Text(s.t(_limitTypes[i].$2)),
                trailing: Text('${limit.defaultValue}  →  ${limit.premiumValue}', style: const TextStyle(fontWeight: FontWeight.w600)),
                onTap: () => account.send<td.Ok>(const td.ViewPremiumFeature(feature: td.PremiumFeatureIncreasedLimits())).ignore(),
              ),
          ]),
        SettingsGroup(children: [
          ListTile(
            leading: const Icon(Icons.redeem_rounded),
            title: Text(s.t('gift_code_apply')),
            onTap: () => _applyGiftCode(context, account),
          ),
        ]),
      ],
    );
  }
}

/// Call before sending the user to subscribe, so Telegram can count the button press.
void premiumSubscribeClicked(TelegramAccount account) => account.send<td.Ok>(const td.ClickPremiumSubscriptionButton()).ignore();

Future<void> _applyGiftCode(BuildContext context, TelegramAccount account) async {
  final s = context.s;
  final input = await promptText(context, title: s.t('gift_code_apply'), label: s.t('gift_code'));
  // Accept both a bare code and a t.me/giftcode/... link.
  final code = input?.trim().split('/').last ?? '';
  if (code.isEmpty || !context.mounted) return;
  final info = await guard(context, () => account.send<td.PremiumGiftCodeInfo>(td.CheckPremiumGiftCode(code: code)));
  if (info == null || !context.mounted) return;
  if (info.useDate > 0) {
    showToast(context, s.t('gift_code_used'));
    return;
  }
  final months = info.monthCount > 0 ? s.t('gift_code_months', {'n': '${info.monthCount}'}) : s.t('gift_code_days', {'n': '${info.dayCount}'});
  final ok = await confirm(context, title: s.t('gift_code_apply'), message: months, confirmLabel: s.t('gift_code_activate'));
  if (!ok || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.ApplyPremiumGiftCode(code: code));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('gift_code_applied'));
}

final _subscriptionsProvider = FutureProvider.autoDispose<td.StarSubscriptions>(
  (ref) => ref.watch(accountProvider).send<td.StarSubscriptions>(const td.GetStarSubscriptions(onlyExpiring: false, offset: '')),
);

/// Paid channel subscriptions in Stars: cancel, renew or rejoin.
class StarSubscriptionsSection extends ConsumerWidget {
  const StarSubscriptionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final subs = ref.watch(_subscriptionsProvider).value?.subscriptions ?? const [];
    if (subs.isEmpty) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    return SettingsGroup(title: s.t('star_subscriptions'), children: [
      for (final sub in subs)
        ListTile(
          leading: ChatAvatar(chatId: sub.chatId, size: 40, showOnline: false),
          title: Text(account.chats[sub.chatId]?.title ?? ''),
          subtitle: Text(
            '${sub.pricing.starCount} ⭐ · ${s.t(sub.isCanceled ? 'subscription_ends' : 'subscription_renews', {'date': formatChatTime(sub.expirationDate, s.locale)})}',
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (action) async {
              await guard(context, () => action == 'rejoin'
                  ? account.send<td.Ok>(td.ReuseStarSubscription(subscriptionId: sub.id))
                  : account.send<td.Ok>(td.EditStarSubscription(subscriptionId: sub.id, isCanceled: action == 'cancel')));
              ref.invalidate(_subscriptionsProvider);
            },
            itemBuilder: (_) => [
              if (!sub.isCanceled) PopupMenuItem(value: 'cancel', child: Text(s.t('subscription_cancel'))),
              if (sub.isCanceled) PopupMenuItem(value: 'renew', child: Text(s.t('subscription_renew'))),
              PopupMenuItem(value: 'rejoin', child: Text(s.t('subscription_rejoin'))),
            ],
          ),
        ),
    ]);
  }
}

/// Gifts on the user's profile: show/hide on profile, convert to Stars.
class MyGiftsScreen extends ConsumerStatefulWidget {
  const MyGiftsScreen({super.key});

  @override
  ConsumerState<MyGiftsScreen> createState() => _MyGiftsScreenState();
}

class _MyGiftsScreenState extends ConsumerState<MyGiftsScreen> {
  td.ReceivedGifts? _gifts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final gifts = await guard(
      context,
      () => account.send<td.ReceivedGifts>(td.GetReceivedGifts(
        businessConnectionId: null,
        ownerId: td.MessageSenderUser(userId: account.myId),
        collectionId: 0,
        excludeUnsaved: false,
        excludeSaved: false,
        excludeUnlimited: false,
        excludeUpgradable: false,
        excludeNonUpgradable: false,
        excludeUpgraded: false,
        excludeWithoutColors: false,
        excludeHosted: false,
        sortByPrice: false,
        offset: '',
        limit: 100,
      )),
    );
    if (mounted) setState(() => _gifts = gifts);
  }

  Future<void> _menu(td.ReceivedGift gift) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(gift.isSaved ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              title: Text(s.t(gift.isSaved ? 'gift_hide' : 'gift_show')),
              onTap: () => Navigator.pop(context, 'save'),
            ),
            if (gift.sellStarCount > 0)
              ListTile(
                leading: const Icon(Icons.star_rounded),
                title: Text(s.t('gift_sell', {'n': '${gift.sellStarCount}'})),
                onTap: () => Navigator.pop(context, 'sell'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'save') {
      await guard(context, () => account.send<td.Ok>(td.ToggleGiftIsSaved(receivedGiftId: gift.receivedGiftId, isSaved: !gift.isSaved)));
    } else {
      final ok = await confirm(context, title: s.t('gift_sell', {'n': '${gift.sellStarCount}'}), message: s.t('gift_sell_hint'), destructive: true);
      if (!ok || !mounted) return;
      await guard(context, () => account.send<td.Ok>(td.SellGift(businessConnectionId: null, receivedGiftId: gift.receivedGiftId)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final gifts = _gifts?.gifts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('my_gifts'))),
      body: gifts == null
          ? const Center(child: CircularProgressIndicator())
          : gifts.isEmpty
              ? Center(child: Text(s.t('nothing_here')))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.8),
                  itemCount: gifts.length,
                  itemBuilder: (context, index) {
                    final gift = gifts[index];
                    final (sticker, label) = switch (gift.gift) {
                      td.SentGiftRegular(:final gift) => (gift.sticker, '${gift.starCount} ⭐'),
                      td.SentGiftUpgraded(:final gift) => (null, '${gift.title} #${gift.number}'),
                      _ => (null, ''),
                    };
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _menu(gift),
                      child: Opacity(
                        opacity: gift.isSaved ? 1 : 0.55,
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                Expanded(child: sticker == null ? const Icon(Icons.card_giftcard_rounded, size: 48) : StickerThumb(sticker: sticker)),
                                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                                if (gift.senderId case final sender?)
                                  Text(account.senderName(sender), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Channel/group boosts: level progress, boosting with the user's free slots, and the boost link.
Future<void> showBoostSheet(BuildContext context, TelegramAccount account, int chatId) async {
  final s = context.s;
  final status = await guard(context, () => account.send<td.ChatBoostStatus>(td.GetChatBoostStatus(chatId: chatId)));
  if (status == null || !context.mounted) return;
  final span = status.nextLevelBoostCount - status.currentLevelBoostCount;
  final progress = span <= 0 ? 1.0 : (status.boostCount - status.currentLevelBoostCount) / span;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('boost_level', {'n': '${status.level}'}), style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.clamp(0, 1), minHeight: 8, borderRadius: BorderRadius.circular(4)),
            const SizedBox(height: 6),
            Text(
              status.nextLevelBoostCount > 0 ? '${status.boostCount} / ${status.nextLevelBoostCount}' : '${status.boostCount}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.bolt_rounded),
              label: Text(s.t('boost_do')),
              onPressed: () async {
                final slots = await guard(context, () => account.send<td.ChatBoostSlots>(const td.GetAvailableChatBoostSlots()));
                if (slots == null || !context.mounted) return;
                final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                final free = [for (final slot in slots.slots) if (slot.currentlyBoostedChatId != chatId && slot.cooldownUntilDate <= now) slot.slotId];
                if (free.isEmpty) {
                  showToast(context, s.t('boost_no_slots'));
                  return;
                }
                final ok = await guard(context, () async {
                  await account.send<td.ChatBoostSlots>(td.BoostChat(chatId: chatId, slotIds: [free.first]));
                  return true;
                });
                if (ok == true && context.mounted) {
                  Navigator.pop(context);
                  showToast(context, s.t('boost_done'));
                }
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.share_rounded),
              label: Text(s.t('boost_share')),
              onPressed: () async {
                final link = await guard(context, () => account.send<td.ChatBoostLink>(td.GetChatBoostLink(chatId: chatId)));
                if (link != null) await SharePlus.instance.share(ShareParams(text: link.link));
              },
            ),
          ],
        ),
      ),
    ),
  );
}

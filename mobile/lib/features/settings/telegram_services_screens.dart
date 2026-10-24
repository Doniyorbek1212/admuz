import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../contacts/contacts_screen.dart';
import '../home/home_screen.dart';
import 'premium_extras.dart';

/// Opens a public chat by @username inside the app (PremiumBot, TelegramTips…).
Future<void> openUsername(BuildContext context, WidgetRef ref, String username) async {
  final chat = await guard(context, () => ref.read(accountProvider).send<td.Chat>(td.SearchPublicChat(username: username)));
  if (chat != null && context.mounted) openChat(context, chat.id);
}

/// Help → Ask a question: Telegram's volunteer warning, then the support chat.
Future<void> askQuestion(BuildContext context, WidgetRef ref) async {
  final s = context.s;
  final ok = await confirm(context, title: s.t('ask_question'), message: s.t('ask_question_text'), confirmLabel: s.t('ask_volunteer'));
  if (!ok || !context.mounted) return;
  final account = ref.read(accountProvider);
  final chat = await guard(context, () async {
    final support = await account.send<td.User>(const td.GetSupportUser());
    return account.openPrivateChat(support.id);
  });
  if (chat != null && context.mounted) openChat(context, chat.id);
}

/// Big centred icon, title and text above a feature list (Premium / Stars / Business pages).
class _Hero extends StatelessWidget {
  const _Hero({required this.icon, required this.colors, required this.title, required this.text});

  final IconData icon;
  final List<Color> colors;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: colors)),
            child: Icon(icon, size: 64, color: Colors.white),
          ),
          const SizedBox(height: 18),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15.5, height: 1.35)),
        ]),
      );
}

/// One feature row: coloured icon, bold title, grey description.
class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.color, this.titleKey);

  final IconData icon;
  final Color color;
  final String titleKey;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: TileIcon(icon, color),
        title: Text(context.t(titleKey), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(context.t('${titleKey}_sub')),
      );
}

class _BuyButton extends StatelessWidget {
  const _BuyButton({required this.label, required this.onPressed});

  static const colors = [Color(0xFF6B8CFF), Color(0xFFB45CF0), Color(0xFFE5609A)];

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), gradient: LinearGradient(colors: colors)),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: onPressed,
              child: SizedBox(
                height: 54,
                child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w600))),
              ),
            ),
          ),
        ),
      );
}

/// Settings → Telegram Premium: what it gives; subscribing goes through @PremiumBot
/// (store purchases need Telegram's own billing, which a third-party app cannot use).
class PremiumInfoScreen extends ConsumerWidget {
  const PremiumInfoScreen({super.key});

  static const _features = [
    (Icons.motion_photos_on_rounded, Color(0xFFFF8A1F), 'prem_stories'),
    (Icons.cloud_upload_rounded, Color(0xFFFF7A59), 'prem_storage'),
    (Icons.exposure_plus_2_rounded, Color(0xFFF2625E), 'prem_limits'),
    (Icons.mic_rounded, Color(0xFFE5486A), 'prem_voice_to_text'),
    (Icons.speed_rounded, Color(0xFFE5486A), 'prem_speed'),
    (Icons.translate_rounded, Color(0xFFDB4B8B), 'prem_translate'),
    (Icons.emoji_emotions_rounded, Color(0xFFD457A8), 'prem_emoji'),
    (Icons.waving_hand_rounded, Color(0xFFC75BC4), 'prem_status'),
    (Icons.bookmarks_rounded, Color(0xFFB45CD9), 'prem_tags'),
    (Icons.palette_rounded, Color(0xFF9B6CE0), 'prem_colors'),
    (Icons.wallpaper_rounded, Color(0xFF8A72EA), 'prem_wallpaper'),
    (Icons.visibility_off_rounded, Color(0xFF7C7BF0), 'prem_last_seen'),
    (Icons.block_rounded, Color(0xFF6B8CFF), 'prem_no_ads'),
    (Icons.verified_rounded, Color(0xFF5A9BFF), 'prem_badge'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final isPremium = ref.watch(meProvider)?.isPremium ?? false;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: const Text('Telegram Premium')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _Hero(
            icon: Icons.star_rounded,
            colors: const [Color(0xFF6B8CFF), Color(0xFFB45CF0)],
            title: 'Telegram Premium',
            text: s.t(isPremium ? 'premium_active' : 'premium_intro'),
          ),
          SettingsGroup(children: [for (final (icon, color, key) in _features) _Feature(icon, color, key)]),
          const PremiumServerSection(),
        ],
      ),
      bottomNavigationBar: isPremium
          ? null
          : _BuyButton(
              label: s.t('premium_subscribe'),
              onPressed: () {
                premiumSubscribeClicked(ref.read(accountProvider));
                openUsername(context, ref, 'PremiumBot');
              },
            ),
    );
  }
}

final _starsProvider = FutureProvider.autoDispose<td.StarTransactions>((ref) {
  final account = ref.watch(accountProvider);
  return account.send<td.StarTransactions>(td.GetStarTransactions(
    ownerId: td.MessageSenderUser(userId: account.myId),
    subscriptionId: '',
    direction: null,
    offset: '',
    limit: 30,
  ));
});

/// Settings → Telegram Stars: balance, buying (via @PremiumBot) and gifting.
class StarsScreen extends ConsumerWidget {
  const StarsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final stars = ref.watch(_starsProvider);
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('telegram_stars'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _Hero(icon: Icons.star_rounded, colors: const [Color(0xFFFFC94D), Color(0xFFF59E0B)], title: s.t('telegram_stars'), text: s.t('stars_intro')),
          SettingsGroup(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.star_rounded, color: Color(0xFFF5B830), size: 40),
                const SizedBox(width: 6),
                Text(
                  stars.when(data: (v) => formatCount(v.starAmount.starCount), loading: () => '…', error: (_, _) => '—'),
                  style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w700),
                ),
              ]),
            ),
            Center(child: Text(s.t('stars_balance'), style: TextStyle(color: Theme.of(context).hintColor))),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(onPressed: () => openUsername(context, ref, 'PremiumBot'), child: Text(s.t('stars_buy'))),
            ),
            TextButton.icon(
              icon: const Icon(Icons.group_rounded),
              label: Text(s.t('stars_gift')),
              onPressed: () => openUsername(context, ref, 'PremiumBot'),
            ),
            const SizedBox(height: 8),
          ]),
          const StarSubscriptionsSection(),
          if (stars.value case final data? when data.transactions.isNotEmpty)
            SettingsGroup(title: s.t('stars_history'), children: [
              for (final t in data.transactions)
                ListTile(
                  leading: Icon(t.starAmount.starCount >= 0 ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded, color: primary),
                  title: Text(formatChatTime(t.date, s.locale)),
                  trailing: Text(
                    '${t.starAmount.starCount > 0 ? '+' : ''}${t.starAmount.starCount} ⭐',
                    style: TextStyle(color: t.starAmount.starCount >= 0 ? const Color(0xFF2EAD5B) : Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
                  ),
                ),
            ]),
        ],
      ),
    );
  }
}

/// Settings → Telegram Business: the business features (part of Premium).
class BusinessInfoScreen extends ConsumerWidget {
  const BusinessInfoScreen({super.key});

  static const _features = [
    (Icons.location_on_rounded, Color(0xFFFF8A1F), 'biz_location'),
    (Icons.schedule_rounded, Color(0xFFFF7A59), 'biz_hours'),
    (Icons.quickreply_rounded, Color(0xFFF2625E), 'biz_quick_replies'),
    (Icons.waving_hand_rounded, Color(0xFFE5486A), 'biz_greeting'),
    (Icons.bedtime_rounded, Color(0xFFD457A8), 'biz_away'),
    (Icons.link_rounded, Color(0xFFB45CD9), 'biz_links'),
    (Icons.info_rounded, Color(0xFF8A72EA), 'biz_intro'),
    (Icons.smart_toy_rounded, Color(0xFF5A9BFF), 'biz_bots'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('telegram_business'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _Hero(icon: Icons.attach_money_rounded, colors: const [Color(0xFF7C4DFF), Color(0xFFE56BD6)], title: s.t('telegram_business'), text: s.t('business_intro')),
          SettingsGroup(children: [for (final (icon, color, key) in _features) _Feature(icon, color, key)]),
          GroupHint(s.t('business_more')),
        ],
      ),
      bottomNavigationBar: _BuyButton(label: s.t('premium_subscribe'), onPressed: () => openUsername(context, ref, 'PremiumBot')),
    );
  }
}

final _giftsProvider = FutureProvider.autoDispose<List<td.AvailableGift>>((ref) async {
  final result = await ref.watch(accountProvider).send<td.AvailableGifts>(const td.GetAvailableGifts());
  return result.gifts;
});

/// Settings → Send a gift: pick a contact, then a gift paid with Stars.
Future<void> sendGiftFlow(BuildContext context) async {
  final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
  if (user == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GiftPickerScreen(user: user)));
}

class GiftPickerScreen extends ConsumerWidget {
  const GiftPickerScreen({super.key, required this.user});

  final td.User user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final gifts = ref.watch(_giftsProvider);
    final name = '${user.firstName} ${user.lastName}'.trim();
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('send_gift'))),
      body: gifts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (list) => CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                UserAvatar(userId: user.id, size: 72),
                const SizedBox(height: 10),
                Text(s.t('gift_to', {'name': name}), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid.count(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.85,
              children: [
                for (final item in list)
                  Material(
                    color: groupCardColor(context),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        final gift = item.gift;
                        final ok = await confirm(context, title: s.t('send_gift'), message: s.t('gift_confirm', {'name': name, 'n': '${gift.starCount}'}));
                        if (!ok || !context.mounted) return;
                        final sent = await guard(
                          context,
                          () => ref.read(accountProvider).send<td.Ok>(td.SendGift(
                                giftId: gift.id,
                                ownerId: td.MessageSenderUser(userId: user.id),
                                text: const td.FormattedText(text: '', entities: []),
                                isPrivate: false,
                                payForUpgrade: false,
                              )),
                        );
                        if (sent != null && context.mounted) {
                          showToast(context, s.t('gift_sent'));
                          Navigator.pop(context);
                        }
                      },
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        SizedBox.square(
                          dimension: 64,
                          child: item.gift.sticker.thumbnail != null
                              ? TdImage(file: item.gift.sticker.thumbnail!.file, width: 64, height: 64, fit: BoxFit.contain)
                              : Center(child: Text(item.gift.sticker.emoji, style: const TextStyle(fontSize: 44))),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(color: const Color(0x33F5B830), borderRadius: BorderRadius.circular(12)),
                          child: Text('⭐ ${item.gift.starCount}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ]),
      ),
    );
  }
}

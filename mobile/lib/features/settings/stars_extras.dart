import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/store_rules.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/composer_panels.dart' show StickerThumb;
import '../chat/payments.dart' show formatInvoiceAmount;
import '../profile/statistics_screen.dart' show StatGraphCard;
import 'privacy_screen.dart' show promptText;

String _starText(td.StarAmount amount) => '${amount.starCount}${amount.nanostarCount != 0 ? '.${(amount.nanostarCount.abs() / 1e7).round()}' : ''} ⭐';

/// Amount in the smallest units of a cryptocurrency (TON uses 9 decimals).
String _crypto(int amount, String currency) => '${(amount / 1e9).toStringAsFixed(2)} $currency';

// ------------------------------------------------------------------ revenue

/// Earnings of a channel/bot/the user: TON ad revenue (chats), Stars revenue, withdrawals and the ad account.
class RevenueScreen extends ConsumerStatefulWidget {
  const RevenueScreen({super.key, required this.owner, this.chatId});

  /// Whose Stars revenue is shown (the user, a bot, or a chat).
  final td.MessageSender owner;

  /// Set for channels: their TON ad revenue is shown too.
  final int? chatId;

  @override
  ConsumerState<RevenueScreen> createState() => _RevenueScreenState();
}

class _RevenueScreenState extends ConsumerState<RevenueScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.ChatRevenueStatistics? _chat;
  td.StarRevenueStatistics? _stars;
  List<td.ChatRevenueTransaction> _transactions = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final chatId = widget.chatId;
    if (chatId != null) {
      try {
        _chat = await _account.send<td.ChatRevenueStatistics>(td.GetChatRevenueStatistics(chatId: chatId, isDark: dark));
        _transactions = (await _account.send<td.ChatRevenueTransactions>(td.GetChatRevenueTransactions(chatId: chatId, offset: '', limit: 50))).transactions;
      } on TdException catch (error) {
        debugPrint('chat revenue unavailable: $error');
      }
    }
    try {
      _stars = await _account.send<td.StarRevenueStatistics>(td.GetStarRevenueStatistics(ownerId: widget.owner, isDark: dark));
    } on TdException catch (error) {
      debugPrint('star revenue unavailable: $error');
    }
    if (mounted) setState(() {});
  }

  Future<String?> _password() => promptText(context, title: context.t('revenue_withdraw'), label: context.t('password'), obscure: true);

  Future<void> _withdrawTon() async {
    final password = await _password();
    if (password == null || password.isEmpty || !mounted) return;
    final url = await guard(context, () => _account.send<td.HttpUrl>(td.GetChatRevenueWithdrawalUrl(chatId: widget.chatId!, password: password)));
    if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
  }

  Future<void> _withdrawStars(int available) async {
    final s = context.s;
    final count = int.tryParse(await promptText(context, title: s.t('revenue_withdraw'), label: '⭐ (≤ $available)', keyboard: TextInputType.number) ?? '');
    if (count == null || count <= 0 || !mounted) return;
    final password = await _password();
    if (password == null || password.isEmpty || !mounted) return;
    final url = await guard(context, () => _account.send<td.HttpUrl>(td.GetStarWithdrawalUrl(ownerId: widget.owner, starCount: count, password: password)));
    if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
  }

  Future<void> _adAccount() async {
    final url = await guard(context, () => _account.send<td.HttpUrl>(td.GetStarAdAccountUrl(ownerId: widget.owner)));
    if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final chat = _chat;
    final stars = _stars;
    final graphChat = widget.chatId ?? (widget.owner is td.MessageSenderChat ? (widget.owner as td.MessageSenderChat).chatId : 0);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('revenue'))),
      body: chat == null && stars == null
          ? Center(child: Text(s.t('revenue_none')))
          : ListView(children: [
              if (chat != null) ...[
                SectionHeader(s.t('revenue_ads')),
                ListTile(
                  title: Text(_crypto(chat.revenueAmount.availableAmount, chat.revenueAmount.cryptocurrency)),
                  subtitle: Text(s.t('revenue_total', {'n': _crypto(chat.revenueAmount.totalAmount, chat.revenueAmount.cryptocurrency)})),
                  trailing: chat.revenueAmount.withdrawalEnabled ? FilledButton(onPressed: _withdrawTon, child: Text(s.t('revenue_withdraw'))) : null,
                ),
                StatGraphCard(chatId: graphChat, title: s.t('revenue_graph'), graph: chat.revenueGraph),
                StatGraphCard(chatId: graphChat, title: s.t('revenue_by_hour'), graph: chat.revenueByHourGraph),
                for (final t in _transactions)
                  ListTile(
                    dense: true,
                    leading: Icon(switch (t.type) {
                      td.ChatRevenueTransactionTypeFragmentWithdrawal() => Icons.north_east_rounded,
                      td.ChatRevenueTransactionTypeFragmentRefund() => Icons.undo_rounded,
                      _ => Icons.south_west_rounded,
                    }),
                    title: Text(_crypto(t.cryptocurrencyAmount, t.cryptocurrency)),
                  ),
              ],
              if (stars != null) ...[
                SectionHeader(s.t('revenue_stars')),
                ListTile(
                  title: Text(_starText(stars.status.availableAmount)),
                  subtitle: Text(s.t('revenue_total', {'n': _starText(stars.status.totalAmount)})),
                  trailing: stars.status.withdrawalEnabled && stars.status.nextWithdrawalIn == 0
                      ? FilledButton(onPressed: () => _withdrawStars(stars.status.availableAmount.starCount), child: Text(s.t('revenue_withdraw')))
                      : null,
                ),
                StatGraphCard(chatId: graphChat, title: s.t('revenue_graph'), graph: stars.revenueByDayGraph),
                if (widget.owner is! td.MessageSenderUser || (widget.owner as td.MessageSenderUser).userId != _account.myId)
                  ListTile(leading: const Icon(Icons.campaign_outlined), title: Text(s.t('revenue_ad_account')), onTap: _adAccount),
              ],
            ]),
    );
  }
}

/// Stars the user has earned from one person's paid messages (shown on that person's profile).
final paidMessageRevenueProvider = FutureProvider.autoDispose.family<int, int>((ref, userId) async {
  try {
    return (await ref.watch(accountProvider).send<td.StarCount>(td.GetPaidMessageRevenue(userId: userId))).starCount;
  } on TdException {
    return 0;
  }
});

/// Group admins: how many Stars members pay per message (the group gets a share).
Future<void> setGroupMessagePrice(BuildContext context, TelegramAccount account, int chatId, int current) async {
  final s = context.s;
  final text = await promptText(context, title: s.t('group_message_price'), label: '⭐ (0 = ${s.t('free')})', keyboard: TextInputType.number, initial: '$current');
  final stars = int.tryParse(text ?? '');
  if (stars == null || stars < 0 || !context.mounted) return;
  await guard(context, () => account.send<td.Ok>(td.SetChatPaidMessageStarCount(chatId: chatId, paidMessageStarCount: stars)));
}

// ------------------------------------------------------------------ boosts

/// Who boosts the chat, what each boost level unlocks, and prepaid giveaways to launch.
class ChatBoostsScreen extends ConsumerStatefulWidget {
  const ChatBoostsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<ChatBoostsScreen> createState() => _ChatBoostsScreenState();
}

class _ChatBoostsScreenState extends ConsumerState<ChatBoostsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.FoundChatBoosts? _boosts;
  td.ChatBoostFeatures? _features;
  td.ChatBoostStatus? _status;
  bool _onlyGifts = false;

  bool get _isChannel {
    final chat = _account.chats[widget.chatId];
    return chat != null && _account.isChannel(chat);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _account.send<td.FoundChatBoosts>(td.GetChatBoosts(chatId: widget.chatId, onlyGiftCodes: _onlyGifts, offset: '', limit: 100)),
        _account.send<td.ChatBoostFeatures>(td.GetChatBoostFeatures(isChannel: _isChannel)),
        _account.send<td.ChatBoostStatus>(td.GetChatBoostStatus(chatId: widget.chatId)),
      ]);
      if (!mounted) return;
      setState(() {
        _boosts = results[0] as td.FoundChatBoosts;
        _features = results[1] as td.ChatBoostFeatures;
        _status = results[2] as td.ChatBoostStatus;
      });
    } on TdException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _showLevel(int level) async {
    final f = await guard(context, () => _account.send<td.ChatBoostLevelFeatures>(td.GetChatBoostLevelFeatures(isChannel: _isChannel, level: level)));
    if (f == null || !mounted) return;
    final s = context.s;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(s.t('boost_level', {'n': '$level'}), style: const TextStyle(fontWeight: FontWeight.w700))),
          for (final (key, value) in [
            ('boost_f_stories', '${f.storyPerDayCount}'),
            ('boost_f_reactions', '${f.customEmojiReactionCount}'),
            ('boost_f_colors', '${f.accentColorCount}'),
            ('boost_f_profile_colors', '${f.profileAccentColorCount}'),
            ('boost_f_themes', '${f.chatThemeBackgroundCount}'),
            if (f.canSetEmojiStatus) ('boost_f_emoji_status', '✓'),
            if (f.canSetCustomBackground) ('boost_f_wallpaper', '✓'),
            if (f.canSetCustomEmojiStickerSet) ('boost_f_emoji_pack', '✓'),
            if (f.canEnableAutomaticTranslation) ('auto_translation', '✓'),
            if (f.canRecognizeSpeech) ('boost_f_speech', '✓'),
            if (f.canDisableSponsoredMessages) ('boost_f_no_ads', '✓'),
          ])
            ListTile(dense: true, title: Text(s.t(key)), trailing: Text(value)),
        ]),
      ),
    );
  }

  Future<void> _launchGiveaway(td.PrepaidGiveaway giveaway) async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('giveaway_launch'), message: s.t('giveaway_launch_hint', {'n': '${giveaway.winnerCount}'}));
    if (!ok || !mounted) return;
    final starCount = switch (giveaway.prize) {
      td.GiveawayPrizeStars(:final starCount) => starCount,
      _ => 0,
    };
    await guard(
      context,
      () => _account.send<td.Ok>(td.LaunchPrepaidGiveaway(
        giveawayId: giveaway.id,
        parameters: td.GiveawayParameters(
          boostedChatId: widget.chatId,
          additionalChatIds: const [],
          winnersSelectionDate: DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
          onlyNewMembers: false,
          hasPublicWinners: true,
          countryCodes: const [],
          prizeDescription: '',
        ),
        winnerCount: giveaway.winnerCount,
        starCount: starCount,
      )),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final boosts = _boosts;
    final features = _features;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('boosts'))),
      body: boosts == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              if (_status case final status?) ...[
                for (final giveaway in status.prepaidGiveaways)
                  ListTile(
                    leading: const Icon(Icons.card_giftcard_rounded),
                    title: Text(s.t('giveaway_prepaid', {'n': '${giveaway.winnerCount}'})),
                    trailing: FilledButton(onPressed: () => _launchGiveaway(giveaway), child: Text(s.t('giveaway_launch'))),
                  ),
              ],
              // What a Premium giveaway for this chat would cost (bought through Telegram's bot or store).
              if (!storeBlocksExternalPayments)
                FutureBuilder<td.PremiumGiveawayPaymentOptions>(
                  future: _account.send<td.PremiumGiveawayPaymentOptions>(td.GetPremiumGiveawayPaymentOptions(boostedChatId: widget.chatId)),
                  builder: (context, snapshot) {
                    final options = snapshot.data?.options ?? const <td.PremiumGiveawayPaymentOption>[];
                    if (options.isEmpty) return const SizedBox.shrink();
                    return ExpansionTile(
                      leading: const Icon(Icons.card_giftcard_rounded),
                      title: Text(s.t('giveaway_prices')),
                      children: [
                        for (final o in options)
                          ListTile(
                            dense: true,
                            title: Text('${s.t('premium_months', {'n': '${o.monthCount}'})} × ${o.winnerCount}'),
                            trailing: Text(formatInvoiceAmount(o.amount, o.currency)),
                          ),
                      ],
                    );
                  },
                ),
              SwitchListTile(
                title: Text(s.t('boosts_gift_codes_only')),
                value: _onlyGifts,
                onChanged: (on) {
                  setState(() => _onlyGifts = on);
                  _load();
                },
              ),
              SectionHeader('${s.t('boosts')} · ${boosts.totalCount}'),
              for (final boost in boosts.boosts)
                ListTile(
                  leading: switch (boost.source) {
                    td.ChatBoostSourcePremium(:final userId) || td.ChatBoostSourceGiftCode(:final userId) => UserAvatar(userId: userId, size: 38),
                    _ => const CircleAvatar(child: Icon(Icons.card_giftcard_rounded)),
                  },
                  title: Text(switch (boost.source) {
                    td.ChatBoostSourcePremium(:final userId) => _account.userName(userId),
                    td.ChatBoostSourceGiftCode(:final userId) => '${_account.userName(userId)} · ${s.t('gift_code')}',
                    td.ChatBoostSourceGiveaway(:final userId, :final isUnclaimed) =>
                      isUnclaimed ? s.t('giveaway_unclaimed') : '${_account.userName(userId)} · ${s.t('giveaway')}',
                    _ => '',
                  }),
                  subtitle: Text(s.t('boost_until', {'date': formatChatTime(boost.expirationDate, s.locale)})),
                  trailing: boost.count > 1 ? Text('×${boost.count}') : null,
                ),
              if (features != null) ...[
                SectionHeader(s.t('boost_levels')),
                for (final f in features.features)
                  ListTile(dense: true, title: Text(s.t('boost_level', {'n': '${f.level}'})), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => _showLevel(f.level)),
              ],
            ]),
    );
  }
}

/// t.me/boost links: opens the boost sheet of that chat (via [showBoost]).
Future<void> openBoostLink(BuildContext context, TelegramAccount account, String url, Future<void> Function(int chatId) showBoost) async {
  final info = await guard(context, () => account.send<td.ChatBoostLinkInfo>(td.GetChatBoostLinkInfo(url: url)));
  if (info == null || info.chatId == 0 || !context.mounted) return;
  await showBoost(info.chatId);
}

/// Groups: how many boosts from one member lift the group's restrictions for them (0 = off).
Future<void> setUnrestrictBoostCount(BuildContext context, TelegramAccount account, int supergroupId, int current) async {
  final s = context.s;
  final picked = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text(s.t('boost_unrestrict'), style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(s.t('boost_unrestrict_hint'))),
        for (var n = 0; n <= 8; n++)
          ListTile(title: Text(n == 0 ? s.t('off') : '$n'), trailing: n == current ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(context, n)),
      ]),
    ),
  );
  if (picked == null || !context.mounted) return;
  await guard(context, () => account.send<td.Ok>(td.SetSupergroupUnrestrictBoostCount(supergroupId: supergroupId, unrestrictBoostCount: picked)));
}

// ------------------------------------------------------------------ giveaways

/// Giveaway message card: prize, winners, and the user's own status on tap.
class GiveawayCard extends ConsumerWidget {
  const GiveawayCard({super.key, required this.message, required this.giveaway});

  final td.Message message;
  final td.MessageGiveaway giveaway;

  Future<void> _details(BuildContext context, TelegramAccount account) async {
    final info = await guard(context, () => account.send<td.GiveawayInfo>(td.GetGiveawayInfo(chatId: message.chatId, messageId: message.id)));
    if (info == null || !context.mounted) return;
    final s = context.s;
    final text = switch (info) {
      td.GiveawayInfoCompleted(:final isWinner, :final winnerCount, :final giftCode, :final wonStarCount, :final wasRefunded) => wasRefunded
          ? s.t('giveaway_refunded')
          : isWinner
              ? s.t('giveaway_won', {'prize': wonStarCount > 0 ? '$wonStarCount ⭐' : giftCode})
              : s.t('giveaway_done', {'n': '$winnerCount'}),
      td.GiveawayInfoOngoing(:final isEnded) => s.t(isEnded ? 'giveaway_choosing' : 'giveaway_ongoing'),
      _ => '',
    };
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(title: Text(s.t('giveaway')), content: Text(text), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))]),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final prize = switch (giveaway.prize) {
      td.GiveawayPrizePremium(:final monthCount) => s.t('giveaway_prize_premium', {'n': '$monthCount'}),
      td.GiveawayPrizeStars(:final starCount) => '$starCount ⭐',
      _ => '',
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (giveaway.sticker case final sticker?) SizedBox.square(dimension: 96, child: StickerThumb(sticker: sticker)),
      Text(s.t('giveaway'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      Text(s.t('giveaway_summary', {'n': '${giveaway.winnerCount}', 'prize': prize})),
      Text(s.t('giveaway_date', {'date': formatChatTime(giveaway.parameters.winnersSelectionDate, s.locale)}), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
      TextButton(onPressed: () => _details(context, ref.read(accountProvider)), child: Text(s.t('details'))),
    ]);
  }
}

// ------------------------------------------------------------------ Premium and Stars catalog

final _premiumFeaturesProvider = FutureProvider.autoDispose<td.PremiumFeatures?>((ref) async {
  try {
    return await ref.watch(accountProvider).send<td.PremiumFeatures>(const td.GetPremiumFeatures(source: null));
  } on TdException {
    return null;
  }
});

final _premiumStickersProvider = FutureProvider.autoDispose<List<td.Sticker>>((ref) async {
  final account = ref.watch(accountProvider);
  try {
    final examples = (await account.send<td.Stickers>(const td.GetPremiumStickerExamples())).stickers;
    if (examples.isNotEmpty) return examples;
    return (await account.send<td.Stickers>(const td.GetPremiumStickers(limit: 20))).stickers;
  } on TdException {
    return const [];
  }
});

/// Extra Premium info from Telegram: higher limits, animated Premium stickers, gift prices.
class PremiumCatalogSection extends ConsumerWidget {
  const PremiumCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final features = ref.watch(_premiumFeaturesProvider).value;
    final stickers = ref.watch(_premiumStickersProvider).value ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (stickers.isNotEmpty) ...[
        SectionHeader(s.t('premium_stickers')),
        SizedBox(
          height: 90,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final sticker in stickers) Padding(padding: const EdgeInsets.all(4), child: SizedBox.square(dimension: 80, child: StickerThumb(sticker: sticker))),
          ]),
        ),
      ],
      if (features != null && features.limits.isNotEmpty) ...[
        SectionHeader(s.t('premium_limits')),
        for (final limit in features.limits)
          ListTile(
            dense: true,
            title: Text(premiumLimitLabel(limit.type, s)),
            trailing: Text('${limit.defaultValue} → ${limit.premiumValue}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
      ],
      if (!storeBlocksExternalPayments)
        FutureBuilder<td.PremiumGiftPaymentOptions>(
          future: account.send<td.PremiumGiftPaymentOptions>(const td.GetPremiumGiftPaymentOptions()),
          builder: (context, snapshot) {
            final options = snapshot.data?.options ?? const <td.PremiumGiftPaymentOption>[];
            if (options.isEmpty) return const SizedBox.shrink();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionHeader(s.t('premium_gift_prices')),
              for (final o in options)
                ListTile(
                  dense: true,
                  leading: FutureBuilder<td.Sticker>(
                    future: account.send<td.Sticker>(td.GetPremiumInfoSticker(monthCount: o.monthCount)),
                    builder: (context, sticker) => SizedBox.square(dimension: 36, child: sticker.data == null ? const Icon(Icons.card_giftcard_rounded) : StickerThumb(sticker: sticker.data!)),
                  ),
                  title: Text(s.t('premium_months', {'n': '${o.monthCount}'})),
                  trailing: Text([formatInvoiceAmount(o.amount, o.currency), if (o.starCount > 0) '${o.starCount} ⭐'].join(' / ')),
                ),
            ]);
          },
        ),
    ]);
  }
}

String premiumLimitLabel(td.PremiumLimitType type, Strings s) => switch (type) {
      td.PremiumLimitTypeSupergroupCount() => s.t('limit_groups'),
      td.PremiumLimitTypePinnedChatCount() => s.t('limit_pinned'),
      td.PremiumLimitTypeCreatedPublicChatCount() => s.t('limit_public_links'),
      td.PremiumLimitTypeSavedAnimationCount() => s.t('limit_gifs'),
      td.PremiumLimitTypeFavoriteStickerCount() => s.t('limit_fav_stickers'),
      td.PremiumLimitTypeChatFolderCount() => s.t('limit_folders'),
      td.PremiumLimitTypeChatFolderChosenChatCount() => s.t('limit_folder_chats'),
      td.PremiumLimitTypeBioLength() => s.t('limit_bio'),
      td.PremiumLimitTypeCaptionLength() => s.t('limit_caption'),
      _ => type.getConstructor().replaceFirst('premiumLimitType', ''),
    };

/// Stars packs Telegram sells, plus gift and giveaway prices; bought through Telegram's own bot or Fragment.
class StarOptionsSection extends ConsumerWidget {
  const StarOptionsSection({super.key, this.giftUserId = 0});

  /// Shows gift prices for this user instead of one's own packs when set.
  final int giftUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (storeBlocksExternalPayments) return const SizedBox.shrink();
    final s = context.s;
    final account = ref.watch(accountProvider);
    return FutureBuilder<List<(String, int, int)>>(
      future: () async {
        final own = giftUserId != 0
            ? await account.send<td.StarPaymentOptions>(td.GetStarGiftPaymentOptions(userId: giftUserId))
            : await account.send<td.StarPaymentOptions>(const td.GetStarPaymentOptions());
        final giveaway = await account.send<td.StarGiveawayPaymentOptions>(const td.GetStarGiveawayPaymentOptions());
        return [
          for (final o in own.options.where((o) => !o.isAdditional)) ('own', o.starCount, o.amount),
          for (final o in giveaway.options.where((o) => o.isDefault)) ('giveaway', o.starCount, o.amount),
        ];
      }(),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const [];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionHeader(s.t('stars_prices')),
          for (final (kind, stars, amount) in rows)
            ListTile(
              dense: true,
              leading: Icon(kind == 'giveaway' ? Icons.card_giftcard_rounded : Icons.star_rounded, color: const Color(0xFFF5B830)),
              title: Text('$stars ⭐${kind == 'giveaway' ? ' · ${s.t('giveaway')}' : ''}'),
              trailing: Text('≈ \$${(amount / 100).toStringAsFixed(2)}'),
            ),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: Text(s.t('stars_buy_fragment')),
            onTap: () => launchUrl(Uri.parse('https://fragment.com/stars/buy'), mode: LaunchMode.externalApplication),
          ),
        ]);
      },
    );
  }
}

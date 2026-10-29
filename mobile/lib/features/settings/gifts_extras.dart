import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/composer_panels.dart' show StickerThumb;
import '../chat/payments.dart' show formatInvoiceAmount;
import '../contacts/contacts_screen.dart';
import 'privacy_screen.dart' show promptText;

td.MessageSender _me(TelegramAccount account) => td.MessageSenderUser(userId: account.myId);

String _giftLabel(td.ReceivedGift gift) => switch (gift.gift) {
      td.SentGiftRegular(:final gift) => '${gift.starCount} ⭐',
      td.SentGiftUpgraded(:final gift) => '${gift.title} #${gift.number}',
      _ => '',
    };

td.Sticker? _giftSticker(td.ReceivedGift gift) => switch (gift.gift) {
      td.SentGiftRegular(:final gift) => gift.sticker,
      td.SentGiftUpgraded(:final gift) => gift.model.sticker,
      _ => null,
    };

Widget _giftTile(BuildContext context, td.ReceivedGift gift, {VoidCallback? onTap, Widget? trailing}) => ListTile(
      leading: SizedBox.square(dimension: 44, child: _giftSticker(gift) == null ? const Icon(Icons.card_giftcard_rounded) : StickerThumb(sticker: _giftSticker(gift)!)),
      title: Text(_giftLabel(gift)),
      subtitle: Text(formatChatTime(gift.date, context.s.locale)),
      trailing: trailing,
      onTap: onTap,
    );

// ------------------------------------------------------------------ more actions on a received gift

/// Extra actions for one of the user's gifts: details, collections, remove original details, NFT export.
Future<void> giftMoreActions(BuildContext context, TelegramAccount account, td.ReceivedGift cached) async {
  final s = context.s;
  // Fresh copy: prices and dates (next transfer, export) change over time.
  final gift = await guard(context, () => account.send<td.ReceivedGift>(td.GetReceivedGift(receivedGiftId: cached.receivedGiftId))) ?? cached;
  if (!context.mounted) return;
  final upgraded = gift.gift is td.SentGiftUpgraded ? (gift.gift as td.SentGiftUpgraded).gift : null;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(_giftLabel(gift), style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: gift.text.text.isEmpty ? null : Text(gift.text.text)),
        if (upgraded != null) ListTile(leading: const Icon(Icons.info_outline_rounded), title: Text(s.t('gift_details')), onTap: () => Navigator.pop(context, 'details')),
        ListTile(leading: const Icon(Icons.collections_bookmark_outlined), title: Text(s.t('gift_collections')), onTap: () => Navigator.pop(context, 'collections')),
        if (gift.dropOriginalDetailsStarCount > 0)
          ListTile(
            leading: const Icon(Icons.person_off_outlined),
            title: Text(s.t('gift_drop_details', {'n': '${gift.dropOriginalDetailsStarCount}'})),
            onTap: () => Navigator.pop(context, 'drop'),
          ),
        if (upgraded != null && gift.exportDate != 0 && gift.exportDate <= now)
          ListTile(leading: const Icon(Icons.account_balance_wallet_outlined), title: Text(s.t('gift_export_nft')), onTap: () => Navigator.pop(context, 'export')),
        if (gift.gift case td.SentGiftRegular(:final gift) when gift.upgradeVariantCount > 0)
          ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: Text(s.t('gift_craft')), onTap: () => Navigator.pop(context, 'craft:${gift.id}')),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'details':
      await showUpgradedGiftInfo(context, account, upgraded!.name);
    case 'collections':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GiftCollectionsScreen(ownerId: _me(account), addGiftId: gift.receivedGiftId)));
    case 'drop':
      final ok = await confirm(context, title: s.t('gift_drop_details', {'n': '${gift.dropOriginalDetailsStarCount}'}), message: s.t('gift_drop_details_hint'), destructive: true);
      if (ok && context.mounted) {
        await guard(context, () => account.send<td.Ok>(td.DropGiftOriginalDetails(receivedGiftId: gift.receivedGiftId, starCount: gift.dropOriginalDetailsStarCount)));
      }
    case 'export':
      final password = await promptText(context, title: s.t('gift_export_nft'), label: s.t('password'), obscure: true);
      if (password == null || password.isEmpty || !context.mounted) return;
      final url = await guard(context, () => account.send<td.HttpUrl>(td.GetUpgradedGiftWithdrawalUrl(receivedGiftId: gift.receivedGiftId, password: password)));
      if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
    default:
      if (action.startsWith('craft:')) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GiftCraftScreen(regularGiftId: int.parse(action.substring(6)))));
      }
  }
}

/// A unique gift: model, value history, owner; can paint the user's name in its colors or set it as status.
Future<void> showUpgradedGiftInfo(BuildContext context, TelegramAccount account, String name) async {
  final gift = await guard(context, () => account.send<td.UpgradedGift>(td.GetUpgradedGift(name: name)));
  if (gift == null || !context.mounted) return;
  td.UpgradedGiftValueInfo? value;
  try {
    value = await account.send<td.UpgradedGiftValueInfo>(td.GetUpgradedGiftValueInfo(name: name));
  } on TdException catch (error) {
    debugPrint('gift value unknown: $error');
  }
  if (!context.mounted) return;
  final s = context.s;
  final colors = gift.colors;
  final mine = switch (gift.ownerId) {
    td.MessageSenderUser(:final userId) => userId == account.myId,
    _ => false,
  };
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        Center(child: SizedBox.square(dimension: 120, child: StickerThumb(sticker: gift.model.sticker))),
        ListTile(title: Text('${gift.title} #${gift.number}', style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('${gift.totalUpgradedCount} / ${gift.maxUpgradedCount}')),
        ListTile(dense: true, title: Text(s.t('gift_model')), trailing: Text(gift.model.name)),
        ListTile(dense: true, title: Text(s.t('gift_symbol')), trailing: Text(gift.symbol.name)),
        ListTile(dense: true, title: Text(s.t('gift_backdrop')), trailing: Text(gift.backdrop.name)),
        if (gift.ownerId case final owner?) ListTile(dense: true, title: Text(s.t('gift_owner')), trailing: Text(account.senderName(owner))),
        if (value != null) ...[
          ListTile(dense: true, title: Text(s.t('gift_value')), trailing: Text(formatInvoiceAmount(value.value, value.currency))),
          if (value.lastSaleDate > 0)
            ListTile(dense: true, title: Text(s.t('gift_last_sale')), trailing: Text('${formatInvoiceAmount(value.lastSalePrice, value.currency)} · ${formatChatTime(value.lastSaleDate, s.locale)}')),
          if (value.fragmentUrl.isNotEmpty)
            ListTile(leading: const Icon(Icons.open_in_new_rounded), title: const Text('Fragment'), onTap: () => launchUrl(Uri.parse(value!.fragmentUrl), mode: LaunchMode.externalApplication)),
        ],
        if (mine && colors != null)
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(s.t('gift_use_colors')),
            onTap: () async {
              await guard(context, () => account.send<td.Ok>(td.SetUpgradedGiftColors(upgradedGiftColorsId: colors.id)));
              if (context.mounted) Navigator.pop(context);
            },
          ),
        if (!mine && gift.canSendPurchaseOffer && gift.ownerId != null)
          ListTile(
            leading: const Icon(Icons.local_offer_outlined),
            title: Text(s.t('gift_make_offer')),
            onTap: () async {
              final text = await promptText(context, title: s.t('gift_make_offer'), label: '⭐', keyboard: TextInputType.number);
              final stars = int.tryParse(text ?? '');
              if (stars == null || stars <= 0 || !context.mounted) return;
              await guard(
                context,
                () => account.send<td.Ok>(td.SendGiftPurchaseOffer(
                  ownerId: gift.ownerId!,
                  giftName: gift.name,
                  price: td.GiftResalePriceStar(starCount: stars),
                  duration: 86400,
                  paidMessageStarCount: 0,
                )),
              );
              if (context.mounted) showToast(context, s.t('gift_offer_sent'));
            },
          ),
      ]),
    ),
  );
}

/// Chat card for an offer to buy one of the user's unique gifts: accept or decline.
class GiftPurchaseOfferCard extends ConsumerWidget {
  const GiftPurchaseOfferCard({super.key, required this.message, required this.offer});

  final td.Message message;
  final td.MessageUpgradedGiftPurchaseOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final price = switch (offer.price) {
      td.GiftResalePriceStar(:final starCount) => '$starCount ⭐',
      _ => '',
    };
    final pending = offer.state is td.GiftPurchaseOfferStatePending;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(dimension: 80, child: StickerThumb(sticker: offer.gift.model.sticker)),
      Text(s.t('gift_offer_for', {'gift': '${offer.gift.title} #${offer.gift.number}', 'price': price}), textAlign: TextAlign.center),
      if (pending && !message.isOutgoing)
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final accept in const [false, true])
            TextButton(
              onPressed: () => guard(context, () => account.send<td.Ok>(td.ProcessGiftPurchaseOffer(messageId: message.id, accept: accept))),
              child: Text(s.t(accept ? 'accept' : 'decline')),
            ),
        ])
      else
        Text(s.t(switch (offer.state) {
          td.GiftPurchaseOfferStateAccepted() => 'gift_offer_accepted',
          td.GiftPurchaseOfferStateRejected() => 'gift_offer_rejected',
          _ => 'gift_offer_pending',
        }), style: TextStyle(color: Theme.of(context).hintColor)),
    ]);
  }
}

// ------------------------------------------------------------------ collections

/// The owner's gift collections; with [addGiftId], tapping a collection adds that gift to it.
class GiftCollectionsScreen extends ConsumerStatefulWidget {
  const GiftCollectionsScreen({super.key, required this.ownerId, this.addGiftId});

  final td.MessageSender ownerId;
  final String? addGiftId;

  @override
  ConsumerState<GiftCollectionsScreen> createState() => _GiftCollectionsScreenState();
}

class _GiftCollectionsScreenState extends ConsumerState<GiftCollectionsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  List<td.GiftCollection>? _collections;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(context, () => _account.send<td.GiftCollections>(td.GetGiftCollections(ownerId: widget.ownerId)));
    if (mounted) setState(() => _collections = result?.collections ?? const []);
  }

  Future<void> _create() async {
    final s = context.s;
    final name = await promptText(context, title: s.t('gift_collection_new'), label: s.t('title'));
    if (name == null || name.trim().isEmpty || !mounted) return;
    await guard(
      context,
      () => _account.send<td.GiftCollection>(td.CreateGiftCollection(
        ownerId: widget.ownerId,
        name: name.trim(),
        receivedGiftIds: [?widget.addGiftId],
      )),
    );
    await _load();
  }

  Future<void> _menu(td.GiftCollection collection) async {
    final s = context.s;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('rename')), onTap: () => Navigator.pop(context, 'rename')),
          ListTile(leading: const Icon(Icons.vertical_align_top_rounded), title: Text(s.t('move_to_top')), onTap: () => Navigator.pop(context, 'top')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'rename':
        final name = await promptText(context, title: s.t('rename'), label: s.t('title'), initial: collection.name);
        if (name == null || name.trim().isEmpty || !mounted) return;
        await guard(context, () => _account.send<td.GiftCollection>(td.SetGiftCollectionName(ownerId: widget.ownerId, collectionId: collection.id, name: name.trim())));
      case 'top':
        final ids = [collection.id, for (final c in _collections ?? const <td.GiftCollection>[]) if (c.id != collection.id) c.id];
        await guard(context, () => _account.send<td.Ok>(td.ReorderGiftCollections(ownerId: widget.ownerId, collectionIds: ids)));
      case 'delete':
        final ok = await confirm(context, title: s.t('delete'), message: collection.name, destructive: true);
        if (ok && mounted) await guard(context, () => _account.send<td.Ok>(td.DeleteGiftCollection(ownerId: widget.ownerId, collectionId: collection.id)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final collections = _collections;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gift_collections'))),
      floatingActionButton: FloatingActionButton(onPressed: _create, child: const Icon(Icons.add_rounded)),
      body: collections == null
          ? const Center(child: CircularProgressIndicator())
          : collections.isEmpty
              ? Center(child: Text(s.t('nothing_here')))
              : ListView(children: [
                  for (final c in collections)
                    ListTile(
                      leading: SizedBox.square(dimension: 40, child: c.icon == null ? const Icon(Icons.collections_bookmark_outlined) : StickerThumb(sticker: c.icon!)),
                      title: Text(c.name),
                      subtitle: Text(s.count('gifts', c.giftCount)),
                      onLongPress: () => _menu(c),
                      onTap: () async {
                        final add = widget.addGiftId;
                        if (add != null) {
                          await guard(context, () => _account.send<td.GiftCollection>(td.AddGiftCollectionGifts(ownerId: widget.ownerId, collectionId: c.id, receivedGiftIds: [add])));
                          if (context.mounted) showToast(context, s.t('done'));
                          await _load();
                          return;
                        }
                        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _CollectionGiftsScreen(ownerId: widget.ownerId, collection: c)));
                        await _load();
                      },
                    ),
                ]),
    );
  }
}

class _CollectionGiftsScreen extends ConsumerStatefulWidget {
  const _CollectionGiftsScreen({required this.ownerId, required this.collection});

  final td.MessageSender ownerId;
  final td.GiftCollection collection;

  @override
  ConsumerState<_CollectionGiftsScreen> createState() => _CollectionGiftsScreenState();
}

class _CollectionGiftsScreenState extends ConsumerState<_CollectionGiftsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  List<td.ReceivedGift>? _gifts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(
      context,
      () => _account.send<td.ReceivedGifts>(td.GetReceivedGifts(
        businessConnectionId: null,
        ownerId: widget.ownerId,
        collectionId: widget.collection.id,
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
    if (mounted) setState(() => _gifts = result?.gifts ?? const []);
  }

  Future<void> _menu(td.ReceivedGift gift) async {
    final s = context.s;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.vertical_align_top_rounded), title: Text(s.t('move_to_top')), onTap: () => Navigator.pop(context, 'top')),
          ListTile(leading: const Icon(Icons.remove_circle_outline_rounded), title: Text(s.t('gift_collection_remove')), onTap: () => Navigator.pop(context, 'remove')),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    final id = widget.collection.id;
    if (action == 'top') {
      final ids = [gift.receivedGiftId, for (final g in _gifts ?? const <td.ReceivedGift>[]) if (g.receivedGiftId != gift.receivedGiftId) g.receivedGiftId];
      await guard(context, () => _account.send<td.GiftCollection>(td.ReorderGiftCollectionGifts(ownerId: widget.ownerId, collectionId: id, receivedGiftIds: ids)));
    } else {
      await guard(context, () => _account.send<td.GiftCollection>(td.RemoveGiftCollectionGifts(ownerId: widget.ownerId, collectionId: id, receivedGiftIds: [gift.receivedGiftId])));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final gifts = _gifts;
    return Scaffold(
      appBar: AppBar(title: Text(widget.collection.name)),
      body: gifts == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [for (final g in gifts) _giftTile(context, g, onTap: () => _menu(g))]),
    );
  }
}

// ------------------------------------------------------------------ crafting

/// Combine several upgraded gifts of one kind into a new one (the used gifts are burned).
class GiftCraftScreen extends ConsumerStatefulWidget {
  const GiftCraftScreen({super.key, required this.regularGiftId});

  final int regularGiftId;

  @override
  ConsumerState<GiftCraftScreen> createState() => _GiftCraftScreenState();
}

class _GiftCraftScreenState extends ConsumerState<GiftCraftScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.GiftsForCrafting? _candidates;
  int _variants = 0;
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final candidates = await guard(context, () => _account.send<td.GiftsForCrafting>(td.GetGiftsForCrafting(regularGiftId: widget.regularGiftId, offset: '', limit: 100)));
    try {
      final variants = await _account.send<td.GiftUpgradePreview>(
        td.GetUpgradedGiftVariants(regularGiftId: widget.regularGiftId, returnUpgradeModels: false, returnCraftModels: true),
      );
      _variants = variants.models.length;
    } on TdException catch (error) {
      debugPrint('craft variants unknown: $error');
    }
    if (mounted) setState(() => _candidates = candidates);
  }

  Future<void> _craft() async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('gift_craft'), message: s.t('gift_craft_hint', {'n': '${_picked.length}'}), destructive: true);
    if (!ok || !mounted) return;
    final result = await guard(context, () => _account.send<td.CraftGiftResult>(td.CraftGift(receivedGiftIds: _picked.toList())));
    if (result == null || !mounted) return;
    switch (result) {
      case td.CraftGiftResultSuccess(:final gift):
        showToast(context, s.t('gift_crafted', {'gift': '${gift.title} #${gift.number}'}));
        Navigator.pop(context);
      default:
        showToast(context, s.t('gift_craft_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final gifts = _candidates?.gifts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gift_craft'))),
      floatingActionButton: _picked.length >= 2 ? FloatingActionButton.extended(onPressed: _craft, icon: const Icon(Icons.auto_awesome_rounded), label: Text(s.t('gift_craft'))) : null,
      body: gifts == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(padding: const EdgeInsets.all(16), child: Text(s.t('gift_craft_intro', {'n': '$_variants'}), style: TextStyle(color: Theme.of(context).hintColor))),
              for (final g in gifts)
                CheckboxListTile(
                  value: _picked.contains(g.receivedGiftId),
                  secondary: SizedBox.square(dimension: 40, child: _giftSticker(g) == null ? null : StickerThumb(sticker: _giftSticker(g)!)),
                  title: Text(_giftLabel(g)),
                  onChanged: (on) => setState(() => on == true ? _picked.add(g.receivedGiftId) : _picked.remove(g.receivedGiftId)),
                ),
            ]),
    );
  }
}

// ------------------------------------------------------------------ resale market

/// Unique gifts of one kind that their owners sell; buying sends the gift to the user.
class GiftResaleScreen extends ConsumerStatefulWidget {
  const GiftResaleScreen({super.key, required this.gift});

  final td.Gift gift;

  @override
  ConsumerState<GiftResaleScreen> createState() => _GiftResaleScreenState();
}

class _GiftResaleScreenState extends ConsumerState<GiftResaleScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.GiftsForResale? _found;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final found = await guard(
      context,
      () => _account.send<td.GiftsForResale>(td.SearchGiftsForResale(
        giftId: widget.gift.id,
        order: const td.GiftForResaleOrderPrice(),
        forCrafting: false,
        forStars: true,
        attributes: const [],
        offset: '',
        limit: 50,
      )),
    );
    if (mounted) setState(() => _found = found);
  }

  Future<void> _buy(td.UpgradedGift gift) async {
    final s = context.s;
    final stars = gift.resaleParameters?.starCount ?? 0;
    final ok = await confirm(context, title: '${gift.title} #${gift.number}', message: s.t('gift_buy_confirm', {'n': '$stars'}));
    if (!ok || !mounted) return;
    final done = await guard(
      context,
      () => _account.send<td.GiftResaleResult>(td.SendResoldGift(
        giftName: gift.name,
        ownerId: _me(_account),
        price: td.GiftResalePriceStar(starCount: stars),
        text: const td.FormattedText(text: '', entities: []),
        isPrivate: false,
      )),
    );
    if (done != null && mounted) {
      showToast(context, s.t('gift_bought'));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final gifts = _found?.gifts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gift_market'))),
      body: gifts == null
          ? const Center(child: CircularProgressIndicator())
          : gifts.isEmpty
              ? Center(child: Text(s.t('nothing_found')))
              : ListView(children: [
                  for (final item in gifts)
                    ListTile(
                      leading: SizedBox.square(dimension: 44, child: StickerThumb(sticker: item.gift.model.sticker)),
                      title: Text('${item.gift.title} #${item.gift.number}'),
                      subtitle: Text('${item.gift.model.name} · ${item.gift.backdrop.name}'),
                      trailing: FilledButton.tonal(onPressed: () => _buy(item.gift), child: Text('${item.gift.resaleParameters?.starCount ?? 0} ⭐')),
                      onLongPress: () => showUpgradedGiftInfo(context, _account, item.gift.name),
                    ),
                ]),
    );
  }
}

// ------------------------------------------------------------------ auctions

/// Live auction for a limited gift: rounds, minimum bid, the user's bid; bid or raise it.
class GiftAuctionScreen extends ConsumerStatefulWidget {
  const GiftAuctionScreen({super.key, required this.gift, required this.receiverUserId});

  final td.Gift gift;

  /// Who receives the gift if the bid wins (usually the user).
  final int receiverUserId;

  @override
  ConsumerState<GiftAuctionScreen> createState() => _GiftAuctionScreenState();
}

class _GiftAuctionScreenState extends ConsumerState<GiftAuctionScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.GiftAuctionState? _state;
  List<td.GiftAuctionAcquiredGift> _won = const [];
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Telegram streams auction updates only while the auction is open on screen.
    _account.send<td.Ok>(td.OpenGiftAuction(giftId: widget.gift.id)).ignore();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _account.send<td.Ok>(td.CloseGiftAuction(giftId: widget.gift.id)).ignore();
    super.dispose();
  }

  Future<void> _load() async {
    final auctionId = widget.gift.auctionInfo?.id;
    if (auctionId == null) return;
    try {
      final state = await _account.send<td.GiftAuctionState>(td.GetGiftAuctionState(auctionId: auctionId));
      final won = await _account.send<td.GiftAuctionAcquiredGifts>(td.GetGiftAuctionAcquiredGifts(giftId: widget.gift.id));
      if (mounted) {
        setState(() {
          _state = state;
          _won = won.gifts;
        });
      }
    } on TdException catch (error) {
      debugPrint('auction state: $error');
    }
  }

  Future<void> _bid(td.AuctionStateActive active) async {
    final s = context.s;
    final mine = active.userBid;
    final min = mine == null ? active.minBid : mine.nextBidStarCount;
    final text = await promptText(context, title: s.t('auction_bid'), label: '⭐ ≥ $min', keyboard: TextInputType.number, initial: '$min');
    final stars = int.tryParse(text ?? '');
    if (stars == null || stars < min || !mounted) return;
    await guard(
      context,
      () => _account.send<td.Ok>(mine == null
          ? td.PlaceGiftAuctionBid(
              giftId: widget.gift.id,
              starCount: stars,
              userId: widget.receiverUserId,
              text: const td.FormattedText(text: '', entities: []),
              isPrivate: false,
            )
          : td.IncreaseGiftAuctionBid(giftId: widget.gift.id, starCount: stars)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final state = _state?.state;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gift_auction'))),
      body: ListView(children: [
        Center(child: SizedBox.square(dimension: 120, child: StickerThumb(sticker: widget.gift.sticker))),
        if (state case td.AuctionStateActive() && final active) ...[
          ListTile(title: Text(s.t('auction_round', {'n': '${active.currentRoundNumber}', 'total': '${active.totalRoundCount}'})), subtitle: Text(s.t('auction_ends', {'date': formatChatTime(active.currentRoundEndDate, s.locale)}))),
          ListTile(dense: true, title: Text(s.t('auction_min_bid')), trailing: Text('${active.minBid} ⭐')),
          ListTile(dense: true, title: Text(s.t('auction_left')), trailing: Text('${active.leftItemCount}')),
          if (active.userBid case final bid?) ListTile(dense: true, title: Text(s.t('auction_my_bid')), trailing: Text('${bid.starCount} ⭐')),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(onPressed: () => _bid(active), child: Text(s.t(active.userBid == null ? 'auction_bid' : 'auction_raise'))),
          ),
        ] else if (state != null)
          ListTile(title: Text(s.t('auction_finished'))),
        if (_won.isNotEmpty) ...[
          SectionHeader(s.t('auction_won')),
          for (final g in _won) ListTile(dense: true, title: Text(account(g.receiverId)), trailing: Text('${g.starCount} ⭐ · #${g.uniqueGiftNumber}')),
        ],
      ]),
    );
  }

  String account(td.MessageSender sender) => _account.senderName(sender);
}

// ------------------------------------------------------------------ small helpers

/// Before sending a limited gift again: Telegram may say it can't be sent yet, with the reason.
Future<bool> checkCanSendGift(BuildContext context, TelegramAccount account, td.Gift gift) async {
  if (gift.nextSendDate == 0) return true;
  final result = await guard(context, () => account.send<td.CanSendGiftResult>(td.CanSendGift(giftId: gift.id)));
  if (result == null || !context.mounted) return false;
  if (result case td.CanSendGiftResultFail(:final reason)) {
    showToast(context, reason.text);
    return false;
  }
  return true;
}

/// Channels: whether gifts sent to the channel post a notification in it.
Future<void> toggleChannelGiftNotifications(BuildContext context, TelegramAccount account, int chatId, bool enabled) =>
    guard(context, () => account.send<td.Ok>(td.ToggleChatGiftNotifications(chatId: chatId, areEnabled: enabled)));

/// Chat themes made from unique gifts the user owns (Telegram's "gift themes").
final giftChatThemesProvider = FutureProvider.autoDispose<List<td.GiftChatTheme>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.GiftChatThemes>(const td.GetGiftChatThemes(offset: '', limit: 50))).themes;
  } on TdException {
    return const [];
  }
});

/// Emoji statuses from upgraded gifts the user owns.
final giftEmojiStatusesProvider = FutureProvider.autoDispose<List<td.EmojiStatus>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.EmojiStatuses>(const td.GetUpgradedGiftEmojiStatuses())).emojiStatuses;
  } on TdException {
    return const [];
  }
});

/// The animation Telegram shows when inviting to upgrade gifts.
final giftPromoAnimationProvider = FutureProvider.autoDispose<td.Animation?>((ref) async {
  try {
    return await ref.watch(accountProvider).send<td.Animation>(const td.GetUpgradedGiftsPromotionalAnimation());
  } on TdException {
    return null;
  }
});

/// Picks a contact to receive a gift bought at an auction.
Future<int?> pickGiftReceiver(BuildContext context, TelegramAccount account) async {
  final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
  return user?.id ?? account.myId;
}

/// Gifts on another user's (or channel's) profile; a regular one whose upgrade was left separate can be
/// upgraded for its owner, and unique ones show their details.
class OwnerGiftsScreen extends ConsumerStatefulWidget {
  const OwnerGiftsScreen({super.key, required this.ownerId});

  final td.MessageSender ownerId;

  @override
  ConsumerState<OwnerGiftsScreen> createState() => _OwnerGiftsScreenState();
}

class _OwnerGiftsScreenState extends ConsumerState<OwnerGiftsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  List<td.ReceivedGift>? _gifts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(
      context,
      () => _account.send<td.ReceivedGifts>(td.GetReceivedGifts(
        businessConnectionId: null,
        ownerId: widget.ownerId,
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
    if (mounted) setState(() => _gifts = result?.gifts ?? const []);
  }

  Future<void> _open(td.ReceivedGift received) async {
    final s = context.s;
    switch (received.gift) {
      case td.SentGiftUpgraded(:final gift):
        await showUpgradedGiftInfo(context, _account, gift.name);
      case td.SentGiftRegular(:final gift) when gift.upgradeStarCount > 0 && received.prepaidUpgradeHash.isNotEmpty:
        final ok = await confirm(context, title: s.t('gift_upgrade'), message: s.t('gift_buy_upgrade_hint', {'n': '${gift.upgradeStarCount}'}));
        if (!ok || !mounted) return;
        await guard(
          context,
          () => _account.send<td.Ok>(td.BuyGiftUpgrade(ownerId: widget.ownerId, prepaidUpgradeHash: received.prepaidUpgradeHash, starCount: gift.upgradeStarCount)),
        );
        await _load();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final gifts = _gifts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('gifts_title'))),
      body: gifts == null
          ? const Center(child: CircularProgressIndicator())
          : gifts.isEmpty
              ? Center(child: Text(s.t('nothing_here')))
              : ListView(children: [for (final g in gifts) _giftTile(context, g, onTap: () => _open(g))]),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/store_rules.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart';
import 'gift_effects.dart';
import 'gift_showcase.dart' show giftShowcaseProvider;
import 'topup_screen.dart';

/// UZARO gifts a Telegram user received (visible ones) and their profile background. Empty when the server is unreachable.
final userGiftsProvider = FutureProvider.autoDispose.family<ProfileGifts, int>((ref, telegramId) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return ProfileGifts.empty;
  try {
    return await api.userGifts(telegramId);
  } on ApiException catch (error) {
    // Offline or timed out: fail so Riverpod retries, rather than showing "no gifts, no background" for good.
    if (error.code == 'NETWORK') rethrow;
    return ProfileGifts.empty;
  }
});

const _seenGiftsKey = 'gifts.seenArrived';
const _seenGiftsKept = 500;
(DateTime, List<SentGift>)? _receivedCache;

/// When this person's chat opens, the newest premium UZARO gift they sent me that this device has not shown yet
/// plays over the chat, once. Received gifts are fetched at most once a minute.
Future<void> playArrivedGift(BuildContext context, WidgetRef ref, int chatId) async {
  final api = ref.read(sadoApiProvider);
  final account = ref.read(accountProvider);
  final chat = account.chats[chatId];
  final sender = chat == null ? null : account.privateUser(chat);
  if (!api.configured || sender == null || sender.id == account.myId || account.isBot(sender)) return;
  final List<SentGift> received;
  if (_receivedCache case (final at, final items) when DateTime.now().difference(at) < const Duration(minutes: 1)) {
    received = items;
  } else {
    try {
      received = (await api.receivedGifts()).$1;
      _receivedCache = (DateTime.now(), received);
    } on ApiException {
      return; // not linked yet, or offline: nothing to show
    }
  }
  final prefs = ref.read(sharedPreferencesProvider);
  final seen = prefs.getStringList(_seenGiftsKey) ?? const <String>[];
  final fresh = [for (final g in received) if (g.senderTelegramId == sender.id && !seen.contains(g.id)) g];
  if (fresh.isEmpty) return;
  final kept = [...seen, ...fresh.map((g) => g.id)];
  await prefs.setStringList(_seenGiftsKey, kept.sublist(math.max(0, kept.length - _seenGiftsKept)));
  // Received gifts come newest first.
  final premium = fresh.where((g) => g.gift.premium).firstOrNull;
  if (premium == null || !context.mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
  await showPremiumGift(context, premium.gift, sent: premium);
}

/// Proves the signed-in Telegram account to the UZARO server: the app sends `/start <one-time code>` to the
/// gifts bot from this account and waits until the server has seen it. True once linked.
Future<bool> ensureGiftsLinked(BuildContext context, WidgetRef ref) async {
  final api = ref.read(sadoApiProvider);
  final account = ref.read(accountProvider);
  final s = context.s;
  try {
    if (await api.telegramId() == account.myId) return true;
    if (!context.mounted) return false;
    showToast(context, s.t('gifts_linking'));
    final link = await api.telegramLinkCode();
    final chat = await account.send<td.Chat>(td.SearchPublicChat(username: link.botUsername));
    final bot = account.privateUser(chat);
    if (bot == null) throw ApiException('GIFTS_BOT_NOT_CONFIGURED');
    await account.send<td.Message>(td.SendBotStartMessage(botUserId: bot.id, chatId: chat.id, parameter: link.code));
    for (var attempt = 0; attempt < 12; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (await api.telegramId() == account.myId) return true;
    }
    if (context.mounted) showToast(context, s.t('gifts_link_failed'));
  } on ApiException catch (error) {
    if (context.mounted) showToast(context, apiErrorText(context, error));
  } on Exception catch (error) {
    if (context.mounted) showToast(context, errorText(context, error));
  }
  return false;
}

/// Animated gift picture (WebP/GIF from the UZARO server).
class GiftImage extends StatelessWidget {
  const GiftImage(this.gift, {super.key, required this.size});

  final GiftItem gift;
  final double size;

  @override
  Widget build(BuildContext context) => Image.network(
        gift.animationUrl,
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Icon(Icons.card_giftcard_rounded, size: size * 0.7, color: Theme.of(context).colorScheme.primary),
      );
}

/// A gift inside a glossy glass bubble (profile gifts and the gift viewer).
class GiftBubble extends StatelessWidget {
  const GiftBubble({super.key, required this.gift, required this.size, this.onTap});

  final GiftItem gift;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        label: gift.titleFor(context.s.locale),
        button: onTap != null,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                center: Alignment(-0.35, -0.45),
                radius: 0.95,
                colors: [Color(0x59FFFFFF), Color(0x268FD8FF), Color(0x146E7CFF), Color(0x6680C8FF)],
                stops: [0, 0.4, 0.78, 1],
              ),
              // Premium gifts get a gold rim and glow.
              border: !gift.premium
                  ? Border.all(color: const Color(0x8CFFFFFF), width: math.max(1, size * 0.012))
                  : Border.all(color: const Color(0xFFFFC542), width: math.max(1.5, size * 0.02)),
              boxShadow: [BoxShadow(color: !gift.premium ?const Color(0x5540B8FF) : const Color(0x80FFB020), blurRadius: size * 0.22)],
            ),
            child: Stack(children: [
              Center(child: GiftImage(gift, size: size * 0.66)),
              // Glass highlight in the upper left.
              Positioned(
                left: size * 0.22,
                top: size * 0.08,
                child: Container(
                  width: size * 0.3,
                  height: size * 0.09,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(size),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x80FFFFFF), Color(0x00FFFFFF)],
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
}

/// Wraps a profile avatar: the person's UZARO gifts float around it in glass bubbles. Shows just [child] when they have none.
class GiftOrbit extends ConsumerStatefulWidget {
  const GiftOrbit({super.key, required this.telegramId, required this.avatarSize, required this.child, this.playVideo = false});

  final int telegramId;
  final double avatarSize;
  final Widget child;

  /// Someone else's profile: their newest premium gift plays full screen once when it opens.
  final bool playVideo;

  @override
  ConsumerState<GiftOrbit> createState() => _GiftOrbitState();
}

class _GiftOrbitState extends ConsumerState<GiftOrbit> with TickerProviderStateMixin {
  /// Where bubbles float, in avatar sizes from its centre (upper sides first), and their sizes.
  static const _slots = [Offset(-1.05, -0.28), Offset(1.05, -0.28), Offset(-1.4, 0.22), Offset(1.4, 0.22), Offset(-0.92, 0.52), Offset(0.92, 0.52)];
  static const _sizes = [0.5, 0.5, 0.4, 0.4, 0.36, 0.36];
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 7))..repeat();

  /// Bubbles the finger moved away from their slot; a released one springs back.
  final Map<int, Offset> _dragged = {};
  int? _held;
  late final AnimationController _springBack = AnimationController(vsync: this, duration: const Duration(milliseconds: 750))
    ..addListener(_onSpring);
  int? _returning;
  Offset _releasedAt = Offset.zero;
  bool _videoPlayed = false;

  @override
  void initState() {
    super.initState();
    if (widget.playVideo) {
      ref.listenManual(userGiftsProvider(widget.telegramId), (_, next) => _maybePlayVideo(next.value), fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _springBack.dispose();
    super.dispose();
  }

  void _maybePlayVideo(ProfileGifts? profile) {
    if (_videoPlayed || profile == null) return;
    final premium = profile.gifts.where((g) => g.gift.premium).firstOrNull;
    if (premium == null) return;
    _videoPlayed = true;
    // After the page transition, and only while this profile is still the screen on top.
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) unawaited(showPremiumGift(context, premium.gift, sent: premium));
    });
  }

  void _onSpring() {
    final i = _returning;
    if (i == null) return;
    setState(() => _dragged[i] = Offset.lerp(_releasedAt, Offset.zero, Curves.elasticOut.transform(_springBack.value))!);
  }

  void _grab(int i) {
    if (_returning == i) _springBack.stop();
    setState(() => _held = i);
  }

  void _move(int i, Offset delta) => setState(() => _dragged[i] = (_dragged[i] ?? Offset.zero) + delta);

  void _release(int i) {
    setState(() => _held = null);
    _returning = i;
    _releasedAt = _dragged[i] ?? Offset.zero;
    unawaited(_springBack.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    final gifts = ref.watch(userGiftsProvider(widget.telegramId)).value?.gifts ?? const <SentGift>[];
    if (gifts.isEmpty) return widget.child;
    final shown = gifts.take(_slots.length).toList();
    final a = widget.avatarSize;
    if (MediaQuery.disableAnimationsOf(context)) _drift.stop();
    return SizedBox(
      width: a * 3.4,
      height: a * 1.5,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          widget.child,
          for (var i = 0; i < shown.length; i++)
            AnimatedBuilder(
              animation: _drift,
              // Each bubble bobs on its own phase so they drift rather than move in step.
              builder: (context, child) {
                final phase = _drift.value * 2 * math.pi + i * 1.7;
                return Transform.translate(
                  offset: Offset(_slots[i].dx * a + math.cos(phase) * a * 0.03, _slots[i].dy * a + math.sin(phase) * a * 0.05) +
                      (_dragged[i] ?? Offset.zero),
                  child: child,
                );
              },
              // Drag right away, or hold first (then the page does not scroll): the bubble follows the finger.
              child: GestureDetector(
                onPanStart: (_) => _grab(i),
                onPanUpdate: (details) => _move(i, details.delta),
                onPanEnd: (_) => _release(i),
                onPanCancel: () => _release(i),
                onLongPressStart: (_) {
                  unawaited(HapticFeedback.selectionClick());
                  _grab(i);
                },
                onLongPressMoveUpdate: (details) => setState(() => _dragged[i] = details.offsetFromOrigin),
                onLongPressEnd: (_) => _release(i),
                child: AnimatedScale(
                  scale: _held == i ? 1.18 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 1100),
                    curve: Interval(i * 0.1, 1, curve: Curves.easeOutBack),
                    builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
                    child: GiftBubble(gift: shown[i].gift, size: a * _sizes[i], onTap: () => showGiftDetails(context, shown[i])),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One received gift, opened from its bubble: a big bubble, who sent it, their words and the date.
Future<void> showGiftDetails(BuildContext context, SentGift sent) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).closeButtonLabel,
      barrierColor: const Color(0x99000000),
      transitionDuration: const Duration(milliseconds: 380),
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn), child: child),
      ),
      pageBuilder: (context, _, _) => Consumer(builder: (context, ref, _) {
        final s = context.s;
        final sender = ref.watch(accountProvider).users[sent.senderTelegramId];
        // A hidden sender (0) reads "anonymous"; when known to this viewer, the hiding is noted next to the name.
        final known = sender == null ? '' : '${sender.firstName} ${sender.lastName}'.trim();
        final name = sent.senderTelegramId == 0
            ? s.t('gifts_anonymous')
            : sent.anonymous && known.isNotEmpty
                ? '$known · ${s.t('gifts_anonymous')}'
                : known;
        return Material(
          type: MaterialType.transparency,
          // The profile behind is blurred so the gift and its words read on any background.
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(context),
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    GiftBubble(gift: sent.gift, size: 230),
                    const SizedBox(height: 18),
                    Text(sent.gift.titleFor(context.s.locale), style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                    if (name.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(s.t('gifts_from', {'name': name}), style: const TextStyle(color: Colors.white70, fontSize: 15)),
                    ],
                    if (sent.text.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('“${sent.text}”', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17, fontStyle: FontStyle.italic)),
                    ],
                    const SizedBox(height: 8),
                    Text(DateFormat('dd.MM.yyyy').format(sent.createdAt.toLocal()), style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ]),
                ),
              ),
            ),
          ),
          ),
        );
      }),
    );

/// The gift shop for the user's own profile: no note, no hidden name.
Future<bool?> buyUzaroGiftForMe(BuildContext context, WidgetRef ref, {GiftItem? initial}) =>
    sendUzaroGift(context, recipientId: ref.read(accountProvider).myId, name: context.t('gifts_for_me'), initial: initial);

/// Gift shop for a person ([recipientId] = their Telegram id) or a group/channel (its chat id): pick a gift,
/// add a few words, pay from the UZARO balance. The user's own id buys the gift for their own profile.
Future<bool?> sendUzaroGift(BuildContext context, {required int recipientId, required String name, GiftItem? initial}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GiftShopSheet(recipientId: recipientId, name: name, initial: initial),
    );

class _GiftShopSheet extends ConsumerStatefulWidget {
  const _GiftShopSheet({required this.recipientId, required this.name, this.initial});

  final int recipientId;
  final String name;
  final GiftItem? initial;

  @override
  ConsumerState<_GiftShopSheet> createState() => _GiftShopSheetState();
}

class _GiftShopSheetState extends ConsumerState<_GiftShopSheet> {
  late Future<(List<GiftItem>, Wallet)> _data = _load();
  late GiftItem? _selected = widget.initial;
  final _text = TextEditingController();
  bool _sending = false;
  bool _anonymous = false;

  /// Bought for the user's own profile rather than sent to someone.
  bool get _forMe => widget.recipientId == ref.read(accountProvider).myId;

  Future<(List<GiftItem>, Wallet)> _load() async {
    final api = ref.read(sadoApiProvider);
    final results = await Future.wait([api.giftCatalog(), api.wallet()]);
    return (results[0] as List<GiftItem>, results[1] as Wallet);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(GiftItem gift) async {
    setState(() => _sending = true);
    final linked = await ensureGiftsLinked(context, ref);
    if (!linked || !mounted) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    final self = _forMe;
    final balance = await apiGuard(
      context,
      () => ref.read(sadoApiProvider).sendGift(gift.id, widget.recipientId, self ? '' : _text.text.trim(), anonymous: !self && _anonymous),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (balance == null) return;
    ref.invalidate(userGiftsProvider(widget.recipientId));
    ref.invalidate(giftShowcaseProvider(widget.recipientId));
    showToast(context, context.t(self ? 'gifts_bought' : 'gifts_sent'));
    final navigator = Navigator.of(context);
    navigator.pop(true);
    // The sender sees the premium show they just bought.
    if (gift.premium) unawaited(showPremiumGift(navigator.context, gift));
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
    final theme = Theme.of(context);
    final name = widget.name;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: FutureBuilder<(List<GiftItem>, Wallet)>(
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
            final (gifts, wallet) = data;
            final selected = _selected;
            final enough = selected != null && wallet.balanceUzs >= selected.priceUzs;
            final self = _forMe;
            return Column(children: [
              Text(self ? name : s.t('gifts_for', {'name': name}), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('${s.t('gifts_balance')}: ${formatUzs(context, wallet.balanceUzs)}', style: TextStyle(color: theme.hintColor)),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 116, childAspectRatio: 0.8, mainAxisSpacing: 8, crossAxisSpacing: 8),
                  itemCount: gifts.length,
                  itemBuilder: (context, i) => _GiftTile(gift: gifts[i], selected: gifts[i].id == selected?.id, onTap: () => setState(() => _selected = gifts[i])),
                ),
              ),
              if (selected != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(children: [
                    if (self)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(s.t('gifts_for_me_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor)),
                      )
                    else ...[
                    TextField(
                      controller: _text,
                      maxLength: 140,
                      decoration: InputDecoration(hintText: s.t('gifts_message_hint'), border: const OutlineInputBorder()),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      secondary: const Icon(Icons.visibility_off_rounded),
                      title: Text(s.t('gifts_hide_my_name')),
                      subtitle: Text(s.t('gifts_hide_my_name_hint')),
                      value: _anonymous,
                      onChanged: _sending ? null : (value) => setState(() => _anonymous = value),
                    ),
                    ],
                    // Store builds: paid gifts are bought from a balance topped up outside the store, which the
                    // store rules forbid; free ones still go.
                    if (!storeBlocksExternalPayments || selected.priceUzs == 0)
                    FilledButton.icon(
                      onPressed: _sending ? null : (enough ? () => _send(selected) : _topUp),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      icon: _sending
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(enough ? (self ? Icons.shopping_bag_rounded : Icons.send_rounded) : Icons.account_balance_wallet_rounded),
                      label: Text(
                        enough ? s.t(self ? 'gifts_buy_me' : 'gifts_buy', {'price': formatUzs(context, selected.priceUzs)}) : s.t('gifts_topup'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(s.t('gifts_only_uzaro'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class _GiftTile extends StatelessWidget {
  const _GiftTile({required this.gift, required this.selected, required this.onTap});

  final GiftItem gift;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Expanded(child: GiftImage(gift, size: 72)),
            Text(gift.titleFor(context.s.locale), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            Text(formatUzs(context, gift.priceUzs), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
